#if canImport(ExecutorCore)
import ExecutorCore
#endif
import Foundation
import Security

actor ExecutorWorkspaceBookmarkStore {
    private let accountData: AccountDataStore

    init(accountData: AccountDataStore) {
        self.accountData = accountData
    }

    func save(_ bookmark: Data, identifier: String, userID: String) throws {
        guard Self.validIdentifier(identifier), bookmark.count <= 128 * 1_024 else {
            throw ExecutorIPCError.malformed
        }
        var values = try load(userID: userID)
        values[identifier] = bookmark
        let data = try PropertyListEncoder().encode(values)
        try accountData.writeSecurely(data, to: try url(userID: userID))
    }

    func bookmark(identifier: String, userID: String) throws -> Data {
        guard Self.validIdentifier(identifier),
              let value = try load(userID: userID)[identifier] else {
            throw ExecutorIPCError.unauthenticated
        }
        return value
    }

    func removeAll(userID: String) throws {
        try? FileManager.default.removeItem(at: url(userID: userID))
    }

    private func load(userID: String) throws -> [String: Data] {
        let file = try url(userID: userID)
        guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
        return try PropertyListDecoder().decode([String: Data].self, from: Data(contentsOf: file))
    }

    private func url(userID: String) throws -> URL {
        try accountData.accountDirectory(for: userID)
            .appendingPathComponent("executor-workspaces.plist")
    }

    private static func validIdentifier(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9._-]{1,128}$", options: .regularExpression) != nil
    }
}

protocol ExecutorSubprocessRunning: Sendable {
    func run(executable: URL, input: Data) async throws -> Data
    func cancel(actionID: String) async
}

actor FixedExecutorSubprocessRunner: ExecutorSubprocessRunning {
    private var processes: [String: Process] = [:]

    func run(executable: URL, input: Data) async throws -> Data {
        guard input.count <= ExecutorIPCRequest.maximumBytes else {
            throw ExecutorIPCError.oversized
        }
        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = executable
        process.arguments = ["--ipc"]
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        let actionID = UUID().uuidString.lowercased()
        processes[actionID] = process
        defer { processes.removeValue(forKey: actionID) }
        try process.run()
        stdin.fileHandleForWriting.write(input)
        try stdin.fileHandleForWriting.close()

        return try await withTaskCancellationHandler {
            async let output = Task.detached {
                stdout.fileHandleForReading.readDataToEndOfFile()
            }.value
            async let diagnostics = Task.detached {
                stderr.fileHandleForReading.readDataToEndOfFile()
            }.value
            let (result, errorData) = await (output, diagnostics)
            process.waitUntilExit()
            guard result.count <= ExecutorIPCResponse.maximumBytes,
                  errorData.count <= 64 * 1_024,
                  process.terminationReason == .exit,
                  process.terminationStatus == 0 else {
                throw ExecutorIPCError.executorUnavailable
            }
            return result
        } onCancel: {
            process.terminate()
        }
    }

    func cancel(actionID: String) async {
        processes.values.forEach { $0.terminate() }
    }
}

protocol ExecutorInstallationVerifying: Sendable {
    func verifiedExecutable() throws -> URL
}

enum ExecutorInstallationError: Error {
    case unsupportedOS
    case unsupportedArchitecture
    case artifacts
    case signature
    case virtualizationEntitlement
}

struct ProductionExecutorInstallationVerifier: ExecutorInstallationVerifying {
    func verifiedExecutable() throws -> URL {
        guard #available(macOS 26.0, *) else {
            throw ExecutorInstallationError.unsupportedOS
        }
        #if !arch(arm64)
        throw ExecutorInstallationError.unsupportedArchitecture
        #else
        let executable = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/PerchExecutor", isDirectory: false)
        guard FileManager.default.isExecutableFile(atPath: executable.path),
              let manifest = Bundle.main.url(
                forResource: "ExecutorArtifacts",
                withExtension: "json"
              ) else {
            throw ExecutorInstallationError.artifacts
        }
        do {
            _ = try ExecutorArtifactManifestVerifier().verify(data: Data(contentsOf: manifest))
        } catch {
            throw ExecutorInstallationError.artifacts
        }
        try verifySameTeamSignature(executable)
        return executable
        #endif
    }

    private func verifySameTeamSignature(_ executable: URL) throws {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(
            executable as CFURL,
            SecCSFlags(),
            &staticCode
        ) == errSecSuccess,
              let staticCode,
              SecStaticCodeCheckValidity(
                staticCode,
                SecCSFlags(rawValue: kSecCSStrictValidate),
                nil
              ) == errSecSuccess,
              let executorTeam = teamIdentifier(staticCode: staticCode) else {
            throw ExecutorInstallationError.signature
        }
        guard let entitlements = signingInformation(staticCode: staticCode)?[
            kSecCodeInfoEntitlementsDict
        ] as? [String: Any],
              entitlements["com.apple.security.virtualization"] as? Bool == true else {
            throw ExecutorInstallationError.virtualizationEntitlement
        }
        var selfCode: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &selfCode) == errSecSuccess,
              let selfCode else {
            throw ExecutorInstallationError.signature
        }
        var selfStaticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(selfCode, SecCSFlags(), &selfStaticCode) == errSecSuccess,
              let selfStaticCode,
              let appTeam = teamIdentifier(staticCode: selfStaticCode),
              appTeam == executorTeam else {
            throw ExecutorInstallationError.signature
        }
    }

    private func teamIdentifier(staticCode: SecStaticCode) -> String? {
        (signingInformation(staticCode: staticCode)?[kSecCodeInfoTeamIdentifier] as? String)
    }

    private func signingInformation(staticCode: SecStaticCode) -> [CFString: Any]? {
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess else { return nil }
        return information as? [CFString: Any]
    }

}

actor ProductionExecutorBackend: DeviceExecutionBackend {
    nonisolated let capabilityState: ExecutorCapabilityState
    private let installation: ExecutorInstallationVerifying
    private let runner: ExecutorSubprocessRunning
    private let identities: DeviceIdentityProviding
    private let bookmarks: ExecutorWorkspaceBookmarkStore

    init(
        identities: DeviceIdentityProviding,
        bookmarks: ExecutorWorkspaceBookmarkStore,
        installation: ExecutorInstallationVerifying = ProductionExecutorInstallationVerifier(),
        runner: ExecutorSubprocessRunning = FixedExecutorSubprocessRunner()
    ) {
        self.identities = identities
        self.bookmarks = bookmarks
        self.installation = installation
        self.runner = runner
        do {
            _ = try installation.verifiedExecutable()
            capabilityState = .available
        } catch ExecutorInstallationError.unsupportedOS {
            capabilityState = .unsupportedOS
        } catch ExecutorInstallationError.unsupportedArchitecture {
            capabilityState = .unsupportedArchitecture
        } catch ExecutorInstallationError.virtualizationEntitlement {
            capabilityState = .virtualizationUnavailable(
                "The executor signature lacks com.apple.security.virtualization"
            )
        } catch {
            capabilityState = .artifactsUnavailable(error.localizedDescription)
        }
    }

    func execute(
        grantPayload: [String: Any],
        deviceID: String,
        userID: String
    ) async throws -> ExecutionResult {
        guard case .available = capabilityState,
              let deviceUUID = UUID(uuidString: deviceID),
              let sessionValue = grantPayload["session_id"] as? String,
              let sessionID = UUID(uuidString: sessionValue),
              let fence = grantPayload["fence"] as? Int,
              let bookmarkID = grantPayload["workspace_bookmark_id"] as? String else {
            throw ExecutorIPCError.executorUnavailable
        }
        let executable = try installation.verifiedExecutable()
        let grantJSON = try JSONSerialization.data(
            withJSONObject: grantPayload,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        let bookmark = try await bookmarks.bookmark(identifier: bookmarkID, userID: userID)
        let identity = try identities.identity(for: userID, createIfMissing: false)
        let publicKey = try identity.publicKey
        guard publicKey.algorithm == "P-256" else { throw ExecutorIPCError.unauthenticated }
        var secret = Data(count: 32)
        guard secret.withUnsafeMutableBytes({
            SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!)
        }) == errSecSuccess else {
            throw ExecutorIPCError.executorUnavailable
        }
        let requestID = UUID()
        let unsigned = ExecutorIPCRequest(
            requestID: requestID,
            sessionID: sessionID,
            deviceID: deviceUUID,
            fence: fence,
            grantJSON: grantJSON,
            workspaceBookmark: bookmark,
            devicePublicKeyPEM: publicKey.value,
            ipcSecret: secret,
            signatureDER: Data([0x30, 0x00])
        )
        let signature = try identity.sign(unsigned.signingData())
        let request = ExecutorIPCRequest(
            requestID: requestID,
            sessionID: sessionID,
            deviceID: deviceUUID,
            fence: fence,
            grantJSON: grantJSON,
            workspaceBookmark: bookmark,
            devicePublicKeyPEM: publicKey.value,
            ipcSecret: secret,
            signatureDER: signature
        )
        let input = try JSONEncoder().encode(request)
        let response = try ExecutorIPCResponse.decode(
            await runner.run(executable: executable, input: input)
        )
        try response.verify(ipcSecret: secret, expectedRequestID: requestID)
        return try Self.executionResult(from: response.resultJSON)
    }

    func cancel(actionID: String) async {
        await runner.cancel(actionID: actionID)
    }

    private static func executionResult(from data: Data) throws -> ExecutionResult {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(value.keys) == Set([
                "status", "exit_code", "stdout", "stderr", "truncated",
                "duration_ms", "redactions",
              ]),
              let statusValue = value["status"] as? String,
              let status = ExecutionResultStatus(rawValue: statusValue),
              let stdout = value["stdout"] as? String,
              let stderr = value["stderr"] as? String,
              let truncated = value["truncated"] as? Bool,
              let duration = value["duration_ms"] as? Int,
              let redactions = value["redactions"] as? Int else {
            throw ExecutorIPCError.malformed
        }
        let exitCode = (value["exit_code"] as? NSNumber).map { Int32($0.intValue) }
        return ExecutionResult(
            status: status,
            exitCode: exitCode,
            stdout: stdout,
            stderr: stderr,
            truncated: truncated,
            durationMilliseconds: duration,
            redactions: redactions
        )
    }
}
