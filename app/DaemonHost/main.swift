import Foundation
import Security
import Darwin

private enum HostConstants {
    static let service = "engineering.super.Perch.daemon"
    static let installationSecret = "installation.secret"
    static let maxLineBytes = 64 * 1024
    static let maxValueBytes = 16 * 1024
    static let maxIDBytes = 128
    static let allowedCredentials: Set<String> = [
        installationSecret,
        "provider.anthropic",
        "provider.openai",
        "provider.openrouter",
        "provider.deepseek",
        "provider.custom_openai",
        "composio",
    ]
}

private enum HostError: Error, CustomStringConvertible {
    case invalidBundleLayout
    case invalidCodeSignature(OSStatus)
    case missingBundledFile(String)
    case unsafeDirectory(String)
    case invalidRequest(String)
    case keychain(OSStatus)
    case childExited(Int32)

    var description: String {
        switch self {
        case .invalidBundleLayout:
            return "invalid host bundle layout"
        case .invalidCodeSignature(let status):
            return "app bundle signature validation failed (\(status))"
        case .missingBundledFile(let name):
            return "missing bundled component: \(name)"
        case .unsafeDirectory(let name):
            return "unsafe private directory: \(name)"
        case .invalidRequest(let reason):
            return "invalid request: \(reason)"
        case .keychain(let status):
            return "Keychain operation failed (\(status))"
        case .childExited(let status):
            return "daemon exited with status \(status)"
        }
    }
}

private struct RPCRequest {
    let id: String
    let operation: String
    let credential: String
    let value: String?

    static func validID(from object: Any) -> String? {
        guard let object = object as? [String: Any],
              let id = object["id"] as? String,
              !id.isEmpty,
              id.utf8.count <= HostConstants.maxIDBytes,
              id.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0)
              })
        else {
            return nil
        }
        return id
    }

    init(json: Any) throws {
        guard let object = json as? [String: Any] else {
            throw HostError.invalidRequest("object required")
        }
        let permittedKeys: Set<String> = ["id", "operation", "credential", "value"]
        guard Set(object.keys).isSubset(of: permittedKeys) else {
            throw HostError.invalidRequest("unknown field")
        }
        guard let id = Self.validID(from: object) else {
            throw HostError.invalidRequest("invalid id")
        }
        guard let operation = object["operation"] as? String,
              ["get", "set", "delete"].contains(operation)
        else {
            throw HostError.invalidRequest("invalid operation")
        }
        guard let credential = object["credential"] as? String,
              HostConstants.allowedCredentials.contains(credential)
        else {
            throw HostError.invalidRequest("credential not allowed")
        }

        let value = object["value"] as? String
        if operation == "set" {
            guard value != nil else {
                throw HostError.invalidRequest("set requires value")
            }
            guard value!.utf8.count <= HostConstants.maxValueBytes else {
                throw HostError.invalidRequest("value too large")
            }
        } else if object["value"] != nil {
            throw HostError.invalidRequest("value only allowed for set")
        }

        self.id = id
        self.operation = operation
        self.credential = credential
        self.value = value
    }
}

private final class KeychainStore {
    private let sharedAccess: SecAccess

    init(appBundle: URL) throws {
        let trustedPaths = [
            CommandLine.arguments[0],
            appBundle.appendingPathComponent("Contents/MacOS/Perch").path,
        ]
        var trustedApplications: [SecTrustedApplication] = []
        for path in trustedPaths {
            var application: SecTrustedApplication?
            let status = SecTrustedApplicationCreateFromPath(path, &application)
            guard status == errSecSuccess, let application else {
                throw HostError.keychain(status)
            }
            trustedApplications.append(application)
        }
        var access: SecAccess?
        let status = SecAccessCreate(
            "Perch local credentials" as CFString,
            trustedApplications as CFArray,
            &access
        )
        guard status == errSecSuccess, let access else {
            throw HostError.keychain(status)
        }
        sharedAccess = access
    }

    static func isValidInstallationSecret(_ encoded: Data) -> Bool {
        guard let decodedValue = Data(base64Encoded: encoded, options: []),
              decodedValue.count == 32
        else {
            return false
        }
        var decoded = decodedValue
        defer { decoded.resetBytes(in: 0..<decoded.count) }
        guard decoded.dropFirst().contains(where: { $0 != decoded.first }) else {
            return false
        }
        var canonical = decoded.base64EncodedData()
        defer { canonical.resetBytes(in: 0..<canonical.count) }
        return canonical == encoded
    }

    func get(_ credential: String) throws -> Data? {
        var result: CFTypeRef?
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: HostConstants.service,
            kSecAttrAccount: credential,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data else {
            throw HostError.keychain(status)
        }
        return data
    }

    func set(_ data: Data, credential: String) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: HostConstants.service,
            kSecAttrAccount: credential,
        ]
        let attributes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrAccess: sharedAccess,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw HostError.keychain(updateStatus)
        }

        var item = query
        item.merge(attributes) { _, new in new }
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw HostError.keychain(addStatus)
        }
    }

    func delete(_ credential: String) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: HostConstants.service,
            kSecAttrAccount: credential,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw HostError.keychain(status)
        }
    }

    func installationSecret() throws -> Data {
        if var existing = try get(HostConstants.installationSecret) {
            defer { existing.resetBytes(in: 0..<existing.count) }
            if Self.isValidInstallationSecret(existing) {
                // Do not rewrite access control on startup. Replacing an ACL
                // causes macOS to request the login-keychain password on every
                // development launch.
                return Data(existing)
            }
            // Malformed legacy material cannot authenticate a session. Remove it
            // before generating a fresh 256-bit value; never echo it in errors.
            try delete(HostConstants.installationSecret)
        }

        var randomBytes = [UInt8](repeating: 0, count: 32)
        defer {
            _ = randomBytes.withUnsafeMutableBytes {
                $0.initializeMemory(as: UInt8.self, repeating: 0)
            }
        }
        let status = randomBytes.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw HostError.keychain(status)
        }
        var encoded = Data(randomBytes).base64EncodedData()
        defer { encoded.resetBytes(in: 0..<encoded.count) }
        try set(encoded, credential: HostConstants.installationSecret)
        return Data(encoded)
    }
}

private struct BundleLayout {
    let appBundle: URL
    let node: URL
    let entrypoint: URL

    static func resolve() throws -> BundleLayout {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0])
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard executable.lastPathComponent == "PerchDaemonHost",
              executable.deletingLastPathComponent().lastPathComponent == "Helpers",
              executable.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "Contents"
        else {
            throw HostError.invalidBundleLayout
        }

        let contents = executable.deletingLastPathComponent().deletingLastPathComponent()
        let appBundle = contents.deletingLastPathComponent()
        guard appBundle.pathExtension == "app" else {
            throw HostError.invalidBundleLayout
        }
        let node = contents.appendingPathComponent("Resources/DaemonRuntime/bin/node")
            .standardizedFileURL.resolvingSymlinksInPath()
        let entrypoint = contents.appendingPathComponent("Resources/Daemon/entry.mjs")
            .standardizedFileURL.resolvingSymlinksInPath()
        let resources = contents.appendingPathComponent("Resources").standardizedFileURL.path + "/"
        guard node.path.hasPrefix(resources), entrypoint.path.hasPrefix(resources) else {
            throw HostError.invalidBundleLayout
        }
        guard FileManager.default.isExecutableFile(atPath: node.path) else {
            throw HostError.missingBundledFile("Node 24 runtime")
        }
        guard FileManager.default.isReadableFile(atPath: entrypoint.path) else {
            throw HostError.missingBundledFile("daemon entrypoint")
        }
        return BundleLayout(appBundle: appBundle, node: node, entrypoint: entrypoint)
    }
}

private func validateStaticSignature(of appBundle: URL) throws {
    var staticCode: SecStaticCode?
    let createStatus = SecStaticCodeCreateWithPath(
        appBundle as CFURL,
        SecCSFlags(),
        &staticCode
    )
    guard createStatus == errSecSuccess, let staticCode else {
        throw HostError.invalidCodeSignature(createStatus)
    }
    let flags = SecCSFlags(rawValue:
        kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate
    )
    var validationError: Unmanaged<CFError>?
    let status = SecStaticCodeCheckValidityWithErrors(
        staticCode,
        flags,
        nil,
        &validationError
    )
    validationError?.release()
    guard status == errSecSuccess else {
        throw HostError.invalidCodeSignature(status)
    }
}

private func securePrivateDirectory(_ url: URL, label: String) throws {
    let path = url.path
    var metadata = stat()
    if lstat(path, &metadata) != 0 {
        guard errno == ENOENT else {
            throw HostError.unsafeDirectory(label)
        }
        do {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
        } catch {
            throw HostError.unsafeDirectory(label)
        }
    }
    let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else {
        throw HostError.unsafeDirectory(label)
    }
    defer { close(descriptor) }
    guard fstat(descriptor, &metadata) == 0,
          (metadata.st_mode & S_IFMT) == S_IFDIR,
          metadata.st_uid == geteuid(),
          fchmod(descriptor, 0o700) == 0
    else {
        throw HostError.unsafeDirectory(label)
    }
    guard fstat(descriptor, &metadata) == 0,
          (metadata.st_mode & 0o077) == 0
    else {
        throw HostError.unsafeDirectory(label)
    }
}

private func secureDaemonDirectories() throws {
    let fileManager = FileManager.default
    let appSupport = fileManager.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
    )[0].appendingPathComponent("Perch", isDirectory: true)
    let library = fileManager.urls(for: .libraryDirectory, in: .userDomainMask)[0]
    let logs = library
        .appendingPathComponent("Logs", isDirectory: true)
        .appendingPathComponent("Perch", isDirectory: true)

    try securePrivateDirectory(appSupport, label: "application support")
    try securePrivateDirectory(
        appSupport.appendingPathComponent("data", isDirectory: true),
        label: "daemon data"
    )
    try securePrivateDirectory(
        appSupport.appendingPathComponent("runtime", isDirectory: true),
        label: "runtime discovery"
    )
    try securePrivateDirectory(logs, label: "daemon logs")
}

private final class JSONLineChannel {
    private let reader: FileHandle
    private let writer: FileHandle
    private var buffer = Data()

    init(reader: FileHandle, writer: FileHandle) {
        self.reader = reader
        self.writer = writer
    }

    deinit {
        buffer.resetBytes(in: 0..<buffer.count)
    }

    func send(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        defer { data.resetBytes(in: 0..<data.count) }
        guard data.count <= HostConstants.maxLineBytes else {
            throw HostError.invalidRequest("outbound line too large")
        }
        data.append(0x0A)
        try writer.write(contentsOf: data)
    }

    func nextObject() throws -> Any? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                var line = Data(buffer.prefix(upTo: newline))
                buffer.removeSubrange(...newline)
                defer {
                    _ = line.withUnsafeMutableBytes { bytes in
                        bytes.initializeMemory(as: UInt8.self, repeating: 0)
                    }
                }
                guard !line.isEmpty, line.count <= HostConstants.maxLineBytes else {
                    throw HostError.invalidRequest("invalid line size")
                }
                return try JSONSerialization.jsonObject(with: line)
            }
            guard buffer.count <= HostConstants.maxLineBytes else {
                throw HostError.invalidRequest("line too large")
            }
            let chunk = reader.availableData
            guard !chunk.isEmpty else {
                guard buffer.isEmpty else {
                    throw HostError.invalidRequest("unterminated line")
                }
                return nil
            }
            buffer.append(chunk)
        }
    }
}

private func response(for request: RPCRequest, store: KeychainStore) -> [String: Any] {
    do {
        switch request.operation {
        case "get":
            var value = try store.get(request.credential)
            defer {
                if value != nil {
                    value!.resetBytes(in: 0..<value!.count)
                }
            }
            var result: [String: Any] = ["id": request.id, "ok": true]
            if let value {
                guard value.count <= HostConstants.maxValueBytes,
                      let string = String(data: value, encoding: .utf8)
                else {
                    throw HostError.invalidRequest("stored value is invalid")
                }
                result["value"] = string
            }
            return result
        case "set":
            var data = Data(request.value!.utf8)
            defer { data.resetBytes(in: 0..<data.count) }
            if request.credential == HostConstants.installationSecret,
               !KeychainStore.isValidInstallationSecret(data) {
                throw HostError.invalidRequest("installation secret must encode exactly 32 bytes")
            }
            try store.set(data, credential: request.credential)
            return ["id": request.id, "ok": true]
        case "delete":
            try store.delete(request.credential)
            return ["id": request.id, "ok": true]
        default:
            return ["id": request.id, "ok": false, "error": "invalid operation"]
        }
    } catch {
        return ["id": request.id, "ok": false, "error": String(describing: error)]
    }
}

private func runSelfTest() throws {
    let valid = try RPCRequest(json: [
        "id": "self-test_1",
        "operation": "set",
        "credential": "provider.anthropic",
        "value": "redacted",
    ])
    guard valid.id == "self-test_1", valid.operation == "set" else {
        throw HostError.invalidRequest("parser self-test failed")
    }
    let invalidRequests: [[String: Any]] = [
        ["id": "../bad", "operation": "get", "credential": "provider.anthropic"],
        ["id": "ok", "operation": "run", "credential": "provider.anthropic"],
        ["id": "ok", "operation": "get", "credential": "not.allowed"],
        ["id": "ok", "operation": "get", "credential": "composio", "value": "unexpected"],
    ]
    for invalid in invalidRequests {
        do {
            _ = try RPCRequest(json: invalid)
            throw HostError.invalidRequest("negative self-test failed")
        } catch HostError.invalidRequest {
            continue
        }
    }
    var validSecret = Data((0..<32).map(UInt8.init)).base64EncodedData()
    defer { validSecret.resetBytes(in: 0..<validSecret.count) }
    var shortSecret = Data((0..<31).map(UInt8.init)).base64EncodedData()
    defer { shortSecret.resetBytes(in: 0..<shortSecret.count) }
    guard KeychainStore.isValidInstallationSecret(validSecret),
          !KeychainStore.isValidInstallationSecret(shortSecret),
          !KeychainStore.isValidInstallationSecret(Data("not-base64".utf8))
    else {
        throw HostError.invalidRequest("installation secret self-test failed")
    }
    FileHandle.standardError.write(Data("PerchDaemonHost self-test passed\n".utf8))
}

private func run() throws {
    if CommandLine.arguments == [CommandLine.arguments[0], "--self-test"] {
        try runSelfTest()
        return
    }
    guard CommandLine.arguments.count == 1 else {
        throw HostError.invalidRequest("arguments are not accepted")
    }

    let layout = try BundleLayout.resolve()
    _ = umask(0o077)
    try secureDaemonDirectories()
    let store = try KeychainStore(appBundle: layout.appBundle)
    var installationSecret = try store.installationSecret()
    defer { installationSecret.resetBytes(in: 0..<installationSecret.count) }
    var installationSecretString = String(data: installationSecret, encoding: .utf8)
    guard installationSecretString != nil else {
        throw HostError.invalidRequest("installation secret encoding")
    }

    let childInput = Pipe()
    let childOutput = Pipe()
    let process = Process()
    process.executableURL = layout.node
    process.arguments = [layout.entrypoint.path]
    process.environment = [:]
    process.currentDirectoryURL = layout.entrypoint.deletingLastPathComponent()
    process.standardInput = childInput
    process.standardOutput = childOutput
    process.standardError = FileHandle.standardError
    // Validate last, immediately before launch. Strict resource validation
    // covers the sealed Node runtime and entry shim in Contents/Resources.
    try validateStaticSignature(of: layout.appBundle)

    // Process children do not automatically die when this host receives a
    // development-stack SIGINT/SIGTERM. Forward both signals so a stopped
    // stack cannot leave an orphan daemon with a dead Keychain RPC channel.
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    let interruptSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    let terminateSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
    let stopChild = {
        if process.isRunning {
            process.terminate()
            let childPID = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                if process.isRunning {
                    _ = Darwin.kill(childPID, SIGKILL)
                }
            }
        }
    }
    interruptSource.setEventHandler(handler: stopChild)
    terminateSource.setEventHandler(handler: stopChild)
    var signalSourcesResumed = false
    defer {
        if !signalSourcesResumed {
            interruptSource.resume()
            terminateSource.resume()
        }
        interruptSource.cancel()
        terminateSource.cancel()
    }

    try process.run()
    interruptSource.resume()
    terminateSource.resume()
    signalSourcesResumed = true

    let channel = JSONLineChannel(
        reader: childOutput.fileHandleForReading,
        writer: childInput.fileHandleForWriting
    )
    try channel.send([
        "type": "bootstrap",
        "installationSecret": installationSecretString!,
    ])
    installationSecret.resetBytes(in: 0..<installationSecret.count)
    installationSecretString = nil

    do {
        FileHandle.standardError.write(Data("[perch-keychain-host] credential loop ready\n".utf8))
        while let object = try channel.nextObject() {
            let request: RPCRequest
            do {
                request = try RPCRequest(json: object)
            } catch {
                guard let id = RPCRequest.validID(from: object) else {
                    process.terminate()
                    throw error
                }
                try channel.send([
                    "id": id,
                    "ok": false,
                    "error": String(describing: error),
                ])
                continue
            }
            FileHandle.standardError.write(Data(
                "[perch-keychain-host] request id=\(request.id) operation=\(request.operation) credential=\(request.credential)\n".utf8
            ))
            let result = response(for: request, store: store)
            let succeeded = result["ok"] as? Bool == true
            FileHandle.standardError.write(Data(
                "[perch-keychain-host] response id=\(request.id) ok=\(succeeded)\n".utf8
            ))
            try channel.send(result)
        }
    } catch {
        if process.isRunning {
            process.terminate()
        }
        throw error
    }

    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw HostError.childExited(process.terminationStatus)
    }
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("PerchDaemonHost: \(error)\n".utf8))
    exit(EXIT_FAILURE)
}
