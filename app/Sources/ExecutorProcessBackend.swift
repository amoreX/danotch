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
        try accountData.installationDirectory(for: userID)
            .appendingPathComponent("executor-workspaces.plist")
    }

    private static func validIdentifier(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9._-]{1,128}$", options: .regularExpression) != nil
    }
}

struct LocalExecutionTerminalResult: Codable, Equatable, Sendable {
    static let maximumCombinedOutputBytes = 1_048_576
    static let maximumDiagnosticBytes = 500

    let status: String
    let exitCode: Int32?
    let stdout: String
    let stderr: String
    let truncated: Bool
    let durationMilliseconds: Int
    let redactions: Int
    let error: String?

    enum CodingKeys: String, CodingKey {
        case status, stdout, stderr, truncated, redactions, error
        case exitCode = "exit_code"
        case durationMilliseconds = "duration_ms"
    }

    init(executionResult result: ExecutionResult) {
        let bounded = Self.bound(stdout: result.stdout, stderr: result.stderr)
        status = result.status.rawValue
        exitCode = result.exitCode
        stdout = bounded.stdout
        stderr = bounded.stderr
        truncated = result.truncated || bounded.truncated
        durationMilliseconds = max(0, result.durationMilliseconds)
        redactions = max(0, result.redactions)
        error = nil
    }

    init(failure: Error) {
        let message = Self.utf8Prefix(
            "Local execution failed: \(failure.localizedDescription)",
            maximumBytes: Self.maximumDiagnosticBytes
        )
        status = ExecutionResultStatus.failed.rawValue
        exitCode = nil
        stdout = ""
        stderr = message
        truncated = false
        durationMilliseconds = 0
        redactions = 0
        error = message
    }

    var protocolObject: [String: Any] {
        var value: [String: Any] = [
            "status": status,
            "exit_code": exitCode.map { Int($0) as Any } ?? NSNull(),
            "stdout": stdout,
            "stderr": stderr,
            "truncated": truncated,
            "duration_ms": durationMilliseconds,
            "redactions": redactions,
        ]
        if let error { value["error"] = error }
        return value
    }

    private static func bound(stdout: String, stderr: String)
        -> (stdout: String, stderr: String, truncated: Bool)
    {
        let output = utf8Prefix(stdout, maximumBytes: maximumCombinedOutputBytes)
        let remaining = max(0, maximumCombinedOutputBytes - output.utf8.count)
        let diagnostics = utf8Prefix(stderr, maximumBytes: remaining)
        return (
            output,
            diagnostics,
            output.utf8.count < stdout.utf8.count || diagnostics.utf8.count < stderr.utf8.count
        )
    }

    private static func utf8Prefix(_ value: String, maximumBytes: Int) -> String {
        guard value.utf8.count > maximumBytes else { return value }
        var end = value.startIndex
        var bytes = 0
        while end < value.endIndex {
            let next = value.index(after: end)
            let width = value[end..<next].utf8.count
            guard bytes + width <= maximumBytes else { break }
            bytes += width
            end = next
        }
        return String(value[..<end])
    }
}

private struct StoredExecutionResponse: Codable {
    let actionID: String
    let requestID: String
    let result: LocalExecutionTerminalResult
}

actor ExecutorRequestLedger {
    private let accountData: AccountDataStore

    init(accountData: AccountDataStore) {
        self.accountData = accountData
    }

    func response(requestID: String, installationID: String) throws -> [String: Any]? {
        try load(installationID: installationID)[requestID].map(Self.payload)
    }

    func save(
        actionID: String,
        requestID: String,
        result: LocalExecutionTerminalResult,
        installationID: String
    ) throws -> [String: Any] {
        var values = try load(installationID: installationID)
        if let existing = values[requestID] { return Self.payload(existing) }
        let response = StoredExecutionResponse(
            actionID: actionID,
            requestID: requestID,
            result: result
        )
        values[requestID] = response
        // Keep a bounded restart ledger. UUID request IDs make insertion order
        // irrelevant, so trim deterministically if corrupted/redelivery traffic
        // ever pushes it beyond the practical limit.
        if values.count > 256 {
            for key in values.keys.sorted().prefix(values.count - 256) {
                values.removeValue(forKey: key)
            }
        }
        try accountData.writeSecurely(
            try PropertyListEncoder().encode(values),
            to: try url(installationID: installationID)
        )
        return Self.payload(response)
    }

    private func load(installationID: String) throws -> [String: StoredExecutionResponse] {
        let file = try url(installationID: installationID)
        guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
        return try PropertyListDecoder().decode(
            [String: StoredExecutionResponse].self,
            from: Data(contentsOf: file)
        )
    }

    private func url(installationID: String) throws -> URL {
        try accountData.installationDirectory(for: installationID)
            .appendingPathComponent("executor-results.plist")
    }

    private static func payload(_ response: StoredExecutionResponse) -> [String: Any] {
        [
            "action_id": response.actionID,
            "request_id": response.requestID,
            "result": response.result.protocolObject,
        ]
    }
}

enum LocalExecutionRequestError: Error, Equatable {
    case malformed
    case stale
}

struct ValidatedLocalExecutionRequest {
    let actionID: String
    let requestID: String
    let grant: [String: Any]

    init(event: [String: Any], installationID: String, now: Date = Date()) throws {
        guard Set(event.keys) == Set(["type", "action_id", "request_id", "grant"]),
              event["type"] as? String == "local_execution_request",
              let actionValue = event["action_id"] as? String,
              let actionUUID = UUID(uuidString: actionValue),
              let requestValue = event["request_id"] as? String,
              let requestUUID = UUID(uuidString: requestValue),
              let grant = event["grant"] as? [String: Any],
              Set(grant.keys) == Set([
                  "grant_id", "action_id", "sequence", "grant_token", "grant_signature",
                  "action_hash", "parameters_hash", "registry_version", "action_type",
                  "normalized_parameters", "capabilities", "image_digest",
                  "workspace_bookmark_id", "result_disclosure_policy", "session_id",
                  "device_key_fingerprint", "device_id", "fence", "expires_at",
                  "transition_id",
              ]),
              Self.uuid(grant["grant_id"]),
              Self.uuid(grant["session_id"]),
              Self.uuid(grant["transition_id"]),
              grant["action_id"] as? String == actionUUID.uuidString.lowercased(),
              grant["device_id"] as? String == installationID.lowercased(),
              grant["sequence"] as? Int == 1,
              (grant["fence"] as? Int).map({ $0 >= 0 }) == true,
              Self.matches(grant["grant_token"], "^[A-Za-z0-9_-]{43}$"),
              Self.matches(grant["grant_signature"], "^[A-Za-z0-9_-]{43}$"),
              Self.matches(grant["action_hash"], "^[a-f0-9]{64}$"),
              Self.matches(grant["parameters_hash"], "^[a-f0-9]{64}$"),
              Self.matches(grant["device_key_fingerprint"], "^[a-f0-9]{64}$"),
              Self.matches(grant["image_digest"], "^sha256:[a-f0-9]{64}$"),
              Self.matches(grant["workspace_bookmark_id"], "^[A-Za-z0-9._-]{1,128}$"),
              let registryVersion = grant["registry_version"] as? String,
              !registryVersion.isEmpty, registryVersion.count <= 32,
              let actionType = grant["action_type"] as? String,
              !actionType.isEmpty, actionType.count <= 128,
              grant["normalized_parameters"] is [String: Any],
              grant["capabilities"] is [String: Any],
              let disclosure = grant["result_disclosure_policy"] as? [String: Any],
              Set(disclosure.keys) == Set(["sensitive_output", "upload"]),
              disclosure["sensitive_output"] is Bool,
              disclosure["upload"] is Bool,
              let expiryValue = grant["expires_at"] as? String,
              let expiry = ISO8601DateFormatter().date(from: expiryValue) else {
            throw LocalExecutionRequestError.malformed
        }
        guard expiry > now else { throw LocalExecutionRequestError.stale }
        actionID = actionUUID.uuidString.lowercased()
        requestID = requestUUID.uuidString.lowercased()
        self.grant = grant
    }

    private static func uuid(_ value: Any?) -> Bool {
        guard let value = value as? String else { return false }
        return UUID(uuidString: value) != nil
            && value == value.lowercased()
            && value.count == 36
    }

    private static func matches(_ value: Any?, _ pattern: String) -> Bool {
        guard let value = value as? String else { return false }
        return value.range(of: pattern, options: .regularExpression) != nil
    }
}

actor LocalExecutionRequestProcessor {
    private let backend: DeviceExecutionBackend
    private let ledger: ExecutorRequestLedger
    private var inFlight: Set<String> = []

    init(backend: DeviceExecutionBackend, accountData: AccountDataStore) {
        self.backend = backend
        ledger = ExecutorRequestLedger(accountData: accountData)
    }

    func handle(
        event: [String: Any],
        installationID: String
    ) async throws -> [String: Any]? {
        let request: ValidatedLocalExecutionRequest
        do {
            request = try ValidatedLocalExecutionRequest(
                event: event,
                installationID: installationID
            )
        } catch LocalExecutionRequestError.stale {
            guard let actionID = Self.validUUID(event["action_id"]),
                  let requestID = Self.validUUID(event["request_id"]) else {
                throw LocalExecutionRequestError.malformed
            }
            return try await ledger.save(
                actionID: actionID,
                requestID: requestID,
                result: LocalExecutionTerminalResult(failure: LocalExecutionRequestError.stale),
                installationID: installationID
            )
        }
        if let stored = try await ledger.response(
            requestID: request.requestID,
            installationID: installationID
        ) {
            return stored
        }
        guard inFlight.insert(request.requestID).inserted else { return nil }
        defer { inFlight.remove(request.requestID) }

        let terminal: LocalExecutionTerminalResult
        do {
            terminal = LocalExecutionTerminalResult(executionResult: try await backend.execute(
                grantPayload: request.grant,
                deviceID: installationID,
                userID: installationID
            ))
        } catch {
            terminal = LocalExecutionTerminalResult(failure: error)
        }
        return try await ledger.save(
            actionID: request.actionID,
            requestID: request.requestID,
            result: terminal,
            installationID: installationID
        )
    }

    private static func validUUID(_ value: Any?) -> String? {
        guard let value = value as? String, let uuid = UUID(uuidString: value) else { return nil }
        return uuid.uuidString.lowercased()
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
    func verifiedInstallation() throws -> VerifiedExecutorInstallation
}

struct VerifiedExecutorInstallation: Sendable {
    let executable: URL
    let manifest: ExecutorArtifactManifestPayload

    var workloadImageDigest: String {
        "sha256:" + manifest.artifacts.first(where: { $0.kind == .workloadImage })!.sha256
    }
}

struct ExecutorCodeSignatureFacts: Equatable, Sendable {
    let appStrictlyValid: Bool
    let executorStrictlyValid: Bool
    let executorHasVirtualizationEntitlement: Bool
    let executorIsNestedInSealedApp: Bool
    let appTeamID: String?
    let executorTeamID: String?
}

enum ExecutorCodeSignaturePolicy {
    static func validate(_ facts: ExecutorCodeSignatureFacts) throws {
        guard facts.appStrictlyValid,
              facts.executorStrictlyValid,
              facts.executorIsNestedInSealedApp else {
            throw ExecutorInstallationError.signature
        }
        guard facts.executorHasVirtualizationEntitlement else {
            throw ExecutorInstallationError.virtualizationEntitlement
        }
        switch (facts.appTeamID, facts.executorTeamID) {
        case let (app?, executor?) where app == executor:
            return
        case (nil, nil):
            // Ad-hoc source builds have no Team ID. Strict validation of both
            // code objects plus containment in the app's seal is the trust
            // boundary; external ad-hoc executables never reach this case.
            return
        default:
            throw ExecutorInstallationError.signature
        }
    }
}

enum ExecutorInstallationError: Error {
    case unsupportedOS
    case unsupportedArchitecture
    case artifacts
    case signature
    case virtualizationEntitlement
}

struct ProductionExecutorInstallationVerifier: ExecutorInstallationVerifying {
    func verifiedInstallation() throws -> VerifiedExecutorInstallation {
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
        let facts = try signatureFacts(executable)
        try ExecutorCodeSignaturePolicy.validate(facts)
        let mode: ExecutorArtifactManifestVerifier.VerificationMode =
            facts.appTeamID == nil ? .enclosingBundleSeal : .signedRelease
        let verifiedManifest: ExecutorArtifactManifestPayload
        do {
            verifiedManifest = try ExecutorArtifactManifestVerifier().verify(
                data: Data(contentsOf: manifest),
                mode: mode
            )
        } catch {
            throw ExecutorInstallationError.artifacts
        }
        return VerifiedExecutorInstallation(
            executable: executable,
            manifest: verifiedManifest
        )
        #endif
    }

    private func signatureFacts(_ executable: URL) throws -> ExecutorCodeSignatureFacts {
        let appURL = Bundle.main.bundleURL.standardizedFileURL
        let expected = appURL
            .appendingPathComponent("Contents/Helpers/PerchExecutor", isDirectory: false)
            .standardizedFileURL
        guard executable.standardizedFileURL == expected else {
            throw ExecutorInstallationError.signature
        }
        let executorCode = try staticCode(at: executable)
        let appCode = try staticCode(at: appURL)
        let strictFlags = SecCSFlags(
            rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures
        )
        let appValid = SecStaticCodeCheckValidity(appCode, strictFlags, nil) == errSecSuccess
        let executorValid = SecStaticCodeCheckValidity(executorCode, strictFlags, nil) == errSecSuccess
        let entitlements = signingInformation(staticCode: executorCode)?[
            kSecCodeInfoEntitlementsDict
        ] as? [String: Any]
        return ExecutorCodeSignatureFacts(
            appStrictlyValid: appValid,
            executorStrictlyValid: executorValid,
            executorHasVirtualizationEntitlement:
                entitlements?["com.apple.security.virtualization"] as? Bool == true,
            executorIsNestedInSealedApp: expected.path.hasPrefix(
                appURL.appendingPathComponent("Contents/Helpers", isDirectory: true).path + "/"
            ),
            appTeamID: teamIdentifier(staticCode: appCode),
            executorTeamID: teamIdentifier(staticCode: executorCode)
        )
    }

    private func staticCode(at url: URL) throws -> SecStaticCode {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(
            url as CFURL,
            SecCSFlags(),
            &staticCode
        ) == errSecSuccess,
              let staticCode else {
            throw ExecutorInstallationError.signature
        }
        return staticCode
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
            _ = try installation.verifiedInstallation()
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
        let executable = try installation.verifiedInstallation().executable
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
