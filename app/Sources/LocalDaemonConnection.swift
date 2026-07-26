import AppKit
#if canImport(ExecutorCore)
import ExecutorCore
#endif
import Darwin
import Foundation
import Security

struct LocalDaemonRuntimeDescriptor: Codable, Equatable {
    let port: Int
    let pid: Int32
    let protocolVersion: Int
    let instanceId: String

    enum CodingKeys: String, CodingKey, CaseIterable {
        case port, pid, protocolVersion, instanceId
    }

    private struct AnyCodingKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    init(port: Int, pid: Int32, protocolVersion: Int, instanceId: String) {
        self.port = port
        self.pid = pid
        self.protocolVersion = protocolVersion
        self.instanceId = instanceId
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.container(keyedBy: AnyCodingKey.self)
        let expected = Set(CodingKeys.allCases.map(\.rawValue))
        guard Set(raw.allKeys.map(\.stringValue)) == expected else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Unexpected descriptor keys")
            )
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        port = try values.decode(Int.self, forKey: .port)
        pid = try values.decode(Int32.self, forKey: .pid)
        protocolVersion = try values.decode(Int.self, forKey: .protocolVersion)
        instanceId = try values.decode(String.self, forKey: .instanceId)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(port, forKey: .port)
        try values.encode(pid, forKey: .pid)
        try values.encode(protocolVersion, forKey: .protocolVersion)
        try values.encode(instanceId, forKey: .instanceId)
    }

    var baseURL: URL {
        URL(string: "http://127.0.0.1:\(port)")!
    }

    func validate(supportedProtocol: Int) throws {
        guard (1...65535).contains(port),
              pid > 0,
              !instanceId.isEmpty,
              instanceId.count <= 128 else {
            throw LocalDaemonError.invalidRuntimeDescriptor
        }
        guard protocolVersion == supportedProtocol else {
            throw LocalDaemonError.unsupportedProtocol
        }
    }
}

enum LocalDaemonError: LocalizedError, Equatable {
    case notInstalled
    case invalidRuntimeDescriptor
    case unsupportedProtocol
    case daemonUnavailable
    case sessionRejected
    case malformedResponse
    case installationSecretMissing
    case installationSecretAccessDenied
    case installationSecretMalformed
    case installationSecretKeychainFailure
    case requestFailed(Int, String)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "The local Perch daemon is not installed."
        case .invalidRuntimeDescriptor:
            return "The local daemon runtime file is invalid."
        case .unsupportedProtocol:
            return "The local daemon requires a different version of Perch."
        case .daemonUnavailable:
            return "The local daemon is not running."
        case .sessionRejected:
            return "The local daemon rejected this app session."
        case .malformedResponse:
            return "The local daemon returned an invalid response."
        case .installationSecretMissing:
            return "The local daemon installation secret is missing. Retry daemon installation."
        case .installationSecretAccessDenied:
            return "Keychain access to the local daemon was denied. Allow access, then retry."
        case .installationSecretMalformed:
            return "The local daemon installation secret is invalid. Retry daemon installation."
        case .installationSecretKeychainFailure:
            return "The local daemon installation secret is unavailable from Keychain."
        case .requestFailed(_, let message):
            return message
        }
    }
}

enum LocalDaemonConnectionState: Equatable {
    case discovering
    case installing
    case connecting(attempt: Int)
    case connected(instanceId: String)
    case offline(reason: String)
    case unsupportedProtocol
    case cancelled

    var title: String {
        switch self {
        case .discovering: return "Finding local daemon"
        case .installing: return "Installing local daemon"
        case .connecting: return "Connecting locally"
        case .connected: return "Local daemon connected"
        case .offline: return "Local daemon unavailable"
        case .unsupportedProtocol: return "Update required"
        case .cancelled: return "Local connection stopped"
        }
    }

    var detail: String {
        switch self {
        case .discovering:
            return "Reading the daemon runtime descriptor."
        case .installing:
            return "Preparing the local background service."
        case .connecting(let attempt):
            return "Opening an authenticated loopback session (attempt \(attempt + 1))."
        case .connected(let instanceId):
            return "Authenticated to this Mac only · \(instanceId.prefix(8))"
        case .offline(let reason):
            return reason
        case .unsupportedProtocol:
            return "Update Perch and its local daemon together."
        case .cancelled:
            return "Retry to reconnect to the local daemon."
        }
    }

    var announcement: String { "\(title). \(detail)" }
    var icon: String {
        switch self {
        case .connected: return "checkmark.circle.fill"
        case .unsupportedProtocol: return "arrow.down.circle"
        case .offline: return "exclamationmark.triangle"
        default: return "externaldrive.connected.to.line.below"
        }
    }
    var canRetry: Bool {
        switch self {
        case .offline, .cancelled: return true
        default: return false
        }
    }
    var canCancel: Bool {
        switch self {
        case .discovering, .installing, .connecting: return true
        default: return false
        }
    }
    var requiresUpdate: Bool { self == .unsupportedProtocol }
    var canReenroll: Bool { false }
    var needsAttention: Bool {
        switch self {
        case .offline, .unsupportedProtocol:
            return true
        default:
            return false
        }
    }
}

protocol LocalDaemonDiscovering {
    func discover() throws -> LocalDaemonRuntimeDescriptor
}

struct RuntimeFileDaemonDiscovery: LocalDaemonDiscovering {
    static let maximumDescriptorSize = 4_096
    let runtimeURL: URL

    init(
        runtimeURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.runtimeURL = runtimeURL ?? fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
            .appendingPathComponent("Perch", isDirectory: true)
            .appendingPathComponent("runtime", isDirectory: true)
            .appendingPathComponent("daemon.json")
    }

    func discover() throws -> LocalDaemonRuntimeDescriptor {
        let descriptor = open(runtimeURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            if errno == ENOENT {
                throw LocalDaemonError.notInstalled
            }
            throw LocalDaemonError.invalidRuntimeDescriptor
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_uid == getuid(),
              (metadata.st_mode & 0o7777) == 0o600,
              metadata.st_size > 0,
              metadata.st_size <= Self.maximumDescriptorSize else {
            throw LocalDaemonError.invalidRuntimeDescriptor
        }
        do {
            guard let data = try handle.readToEnd(),
                  data.count == Int(metadata.st_size),
                  data.count <= Self.maximumDescriptorSize else {
                throw LocalDaemonError.invalidRuntimeDescriptor
            }
            return try JSONDecoder().decode(
                LocalDaemonRuntimeDescriptor.self,
                from: data
            )
        } catch let error as LocalDaemonError {
            throw error
        } catch {
            throw LocalDaemonError.invalidRuntimeDescriptor
        }
    }
}

/// Integration seam for the native daemon host. The app target only needs to
/// discover an existing runtime today; the signed installer can replace this
/// implementation without changing the UI or session protocol.
protocol LocalDaemonBootstrapping {
    func ensureDaemonAvailable() async throws -> LocalDaemonRuntimeDescriptor
}

struct DiscoverOnlyDaemonBootstrap: LocalDaemonBootstrapping {
    let discovery: LocalDaemonDiscovering

    init(discovery: LocalDaemonDiscovering = RuntimeFileDaemonDiscovery()) {
        self.discovery = discovery
    }

    func ensureDaemonAvailable() async throws -> LocalDaemonRuntimeDescriptor {
        try discovery.discover()
    }
}

struct LocalInstallationIdentity: Codable, Equatable {
    let id: String
    let createdAt: Date
}

final class LocalInstallationIdentityStore {
    private let url: URL
    private let fileManager: FileManager

    init(rootURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let root = rootURL ?? fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("Perch", isDirectory: true)
        self.url = root.appendingPathComponent("installation.json")
    }

    func loadOrCreate() throws -> LocalInstallationIdentity {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: url),
           let identity = try? decoder.decode(LocalInstallationIdentity.self, from: data),
           UUID(uuidString: identity.id) != nil {
            return identity
        }
        let identity = LocalInstallationIdentity(
            id: UUID().uuidString.lowercased(),
            createdAt: Date()
        )
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(identity).write(to: url, options: [.atomic])
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: url.path
        )
        return identity
    }
}

struct LocalInstallationSecret {
    fileprivate var encodedBytes: [UInt8]

    init(validatingBase64 value: String) throws {
        guard var decoded = Data(base64Encoded: value),
              decoded.count == 32,
              decoded.base64EncodedString() == value else {
            throw LocalDaemonError.installationSecretMalformed
        }
        defer {
            decoded.resetBytes(in: decoded.startIndex..<decoded.endIndex)
        }
        encodedBytes = Array(value.utf8)
    }

    fileprivate mutating func withBase64String<T>(_ body: (String) throws -> T) throws -> T {
        guard let value = String(bytes: encodedBytes, encoding: .utf8) else {
            throw LocalDaemonError.installationSecretMalformed
        }
        return try body(value)
    }

    fileprivate mutating func zero() {
        _ = encodedBytes.withUnsafeMutableBytes { buffer in
            buffer.initializeMemory(as: UInt8.self, repeating: 0)
        }
        encodedBytes.removeAll(keepingCapacity: false)
    }
}

protocol LocalInstallationSecretReading {
    func readInstallationSecret() throws -> LocalInstallationSecret
}

struct SecurityInstallationSecretReader: LocalInstallationSecretReading {
    static let service = "engineering.super.Perch.daemon"
    static let account = "installation.secret"

    private let keychain: KeychainDataClient

    init(keychain: KeychainDataClient = SystemKeychainDataClient()) {
        self.keychain = keychain
    }

    func readInstallationSecret() throws -> LocalInstallationSecret {
        var stored: Data
        do {
            stored = try keychain.read(service: Self.service, account: Self.account)
        } catch SecureStoreError.missing {
            throw LocalDaemonError.installationSecretMissing
        } catch SecureStoreError.interactionDenied {
            throw LocalDaemonError.installationSecretAccessDenied
        } catch {
            throw LocalDaemonError.installationSecretKeychainFailure
        }
        defer {
            stored.resetBytes(in: stored.startIndex..<stored.endIndex)
        }

        guard let encoded = String(data: stored, encoding: .utf8) else {
            throw LocalDaemonError.installationSecretMalformed
        }
        return try LocalInstallationSecret(validatingBase64: encoded)
    }
}

protocol LocalDaemonSocket: AnyObject {
    func receive() async throws -> Data
    func send(_ data: Data) async throws
    func cancel()
}

struct LocalDaemonSession {
    let token: String
    let socket: LocalDaemonSocket
}

protocol LocalDaemonSessionEstablishing {
    func establish(
        descriptor: LocalDaemonRuntimeDescriptor,
        installation: LocalInstallationIdentity
    ) async throws -> LocalDaemonSession
}

private final class URLSessionLocalDaemonSocket: LocalDaemonSocket {
    private let task: URLSessionWebSocketTask

    init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    func receive() async throws -> Data {
        switch try await task.receive() {
        case .data(let data): return data
        case .string(let value): return Data(value.utf8)
        @unknown default: throw LocalDaemonError.malformedResponse
        }
    }

    func send(_ data: Data) async throws {
        try await task.send(.data(data))
    }

    func cancel() {
        task.cancel(with: .goingAway, reason: nil)
    }
}

struct URLSessionLocalDaemonSessionEstablisher: LocalDaemonSessionEstablishing {
    let urlSession: URLSession
    let secretReader: LocalInstallationSecretReading

    init(
        urlSession: URLSession = .shared,
        secretReader: LocalInstallationSecretReading = SecurityInstallationSecretReader()
    ) {
        self.urlSession = urlSession
        self.secretReader = secretReader
    }

    func establish(
        descriptor: LocalDaemonRuntimeDescriptor,
        installation: LocalInstallationIdentity
    ) async throws -> LocalDaemonSession {
        var secret = try secretReader.readInstallationSecret()
        defer { secret.zero() }
        var body: [String: Any] = [
            "installation_id": installation.id,
            "instance_id": descriptor.instanceId,
            "protocol_versions": [LocalDaemonConnection.protocolVersion],
        ]
        try secret.withBase64String { value in
            body["installation_secret"] = value
        }
        var bodyData = try JSONSerialization.data(withJSONObject: body)
        body.removeAll(keepingCapacity: false)
        defer {
            bodyData.resetBytes(in: bodyData.startIndex..<bodyData.endIndex)
        }
        var request = URLRequest(url: descriptor.baseURL.appendingPathComponent("v1/session"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("perch://app", forHTTPHeaderField: "Origin")
        request.httpBody = bodyData
        let (data, response) = try await urlSession.data(for: request)
        request.httpBody = nil
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["session_token"] as? String,
              token.count >= 32,
              let socketPath = json["websocket_path"] as? String,
              socketPath.hasPrefix("/"),
              !socketPath.contains("://") else {
            throw LocalDaemonError.sessionRejected
        }
        var components = URLComponents(url: descriptor.baseURL, resolvingAgainstBaseURL: false)!
        components.scheme = "ws"
        components.path = socketPath
        guard let socketURL = components.url else { throw LocalDaemonError.malformedResponse }
        var socketRequest = URLRequest(url: socketURL)
        socketRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        socketRequest.setValue("perch://app", forHTTPHeaderField: "Origin")
        socketRequest.setValue(
            "perch.local.v\(LocalDaemonConnection.protocolVersion)",
            forHTTPHeaderField: "Sec-WebSocket-Protocol"
        )
        let task = urlSession.webSocketTask(with: socketRequest)
        task.resume()
        return LocalDaemonSession(token: token, socket: URLSessionLocalDaemonSocket(task: task))
    }
}

final class LocalDaemonConnection: ObservableObject {
    static let protocolVersion = 1

    @Published private(set) var state: LocalDaemonConnectionState = .discovering
    @Published private(set) var installationID: String?
    @Published private(set) var composioConfigured = false

    var onEvent: ((String, [String: Any]) -> Void)?
    var onStateAnnouncement: ((String) -> Void)?

    private let bootstrap: LocalDaemonBootstrapping
    private let sessions: LocalDaemonSessionEstablishing
    private let identities: LocalInstallationIdentityStore
    private let urlSession: URLSession
    private var descriptor: LocalDaemonRuntimeDescriptor?
    private var sessionToken: String?
    private var socket: LocalDaemonSocket?
    private var connectionTask: Task<Void, Never>?
    private var generation = 0

    init(
        bootstrap: LocalDaemonBootstrapping = DiscoverOnlyDaemonBootstrap(),
        sessions: LocalDaemonSessionEstablishing = URLSessionLocalDaemonSessionEstablisher(),
        identities: LocalInstallationIdentityStore = LocalInstallationIdentityStore(),
        urlSession: URLSession = .shared
    ) {
        self.bootstrap = bootstrap
        self.sessions = sessions
        self.identities = identities
        self.urlSession = urlSession
    }

    var executorCapabilityState: ExecutorCapabilityState {
        #if arch(arm64)
        if #available(macOS 26, *) { return .available }
        return .unsupportedOS
        #else
        return .unsupportedArchitecture
        #endif
    }

    func start() {
        cancel(markCancelled: false)
        generation += 1
        let currentGeneration = generation
        connectionTask = Task { [weak self] in
            await self?.run(generation: currentGeneration)
        }
    }

    func retry() {
        start()
    }

    func cancel(markCancelled: Bool = true) {
        generation += 1
        connectionTask?.cancel()
        connectionTask = nil
        socket?.cancel()
        socket = nil
        sessionToken = nil
        descriptor = nil
        if markCancelled { setState(.cancelled) }
    }

    func request(
        _ path: String,
        method: String = "GET",
        json: [String: Any]? = nil
    ) async throws -> Data {
        guard descriptor != nil, sessionToken != nil else {
            throw LocalDaemonError.daemonUnavailable
        }
        let response = try await performRequest(path, method: method, json: json)
        if response.status == 401 {
            try await renewSessionToken()
            let retried = try await performRequest(path, method: method, json: json)
            return try validatedData(from: retried)
        }
        return try validatedData(from: response)
    }

    private func performRequest(
        _ path: String,
        method: String,
        json: [String: Any]?
    ) async throws -> (data: Data, status: Int) {
        guard let descriptor, let sessionToken else {
            throw LocalDaemonError.daemonUnavailable
        }
        let normalized = path.hasPrefix("/") ? String(path.dropFirst()) : path
        var request = URLRequest(url: descriptor.baseURL.appendingPathComponent(normalized))
        request.timeoutInterval = 15
        request.httpMethod = method
        request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        request.setValue("perch://app", forHTTPHeaderField: "Origin")
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        let (data, response) = try await urlSession.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (data, status)
    }

    private func validatedData(from response: (data: Data, status: Int)) throws -> Data {
        guard (200...299).contains(response.status) else {
            let payload = (
                try? JSONSerialization.jsonObject(with: response.data) as? [String: Any]
            ) ?? [:]
            throw LocalDaemonError.requestFailed(
                response.status,
                payload["error"] as? String ?? "Local daemon request failed."
            )
        }
        return response.data
    }

    private func renewSessionToken() async throws {
        guard let descriptor else { throw LocalDaemonError.daemonUnavailable }
        let identity = try identities.loadOrCreate()
        let renewed = try await sessions.establish(
            descriptor: descriptor,
            installation: identity
        )
        // The existing event socket remains valid after its handshake. This
        // exchange is only for a fresh HTTP bearer token.
        renewed.socket.cancel()
        sessionToken = renewed.token
    }

    func send(type: String, payload: [String: Any]) async throws {
        guard let socket else { throw LocalDaemonError.daemonUnavailable }
        let envelope: [String: Any] = [
            "v": Self.protocolVersion,
            "type": type,
            "id": UUID().uuidString.lowercased(),
            "payload": payload,
        ]
        try await socket.send(JSONSerialization.data(withJSONObject: envelope))
    }

    func approveLocalAction(
        actionID: UUID,
        actionHash: String,
        parametersHash: String,
        workspaceURL: URL,
        workspaceBookmarkID: String,
        highRiskShell: Bool,
        expiresAt: String,
        deviceID: String,
        deviceKeyFingerprint: String,
        imageDigest: String
    ) async throws {
        let payload: [String: Any] = [
            "action_id": actionID.uuidString.lowercased(),
            "decision": "approved",
            "action_hash": actionHash,
            "parameters_hash": parametersHash,
            "workspace_bookmark_id": workspaceBookmarkID,
            "workspace_path": workspaceURL.path,
            "high_risk_shell": highRiskShell,
            "expires_at": expiresAt,
            "device_id": deviceID.lowercased(),
            "device_key_fingerprint": deviceKeyFingerprint,
            "image_digest": imageDigest,
        ]
        try await send(type: "action_decision", payload: payload)
    }

    func rejectLocalAction(
        actionID: UUID,
        actionHash: String,
        parametersHash: String,
        workspaceBookmarkID: String,
        expiresAt: String
    ) async throws {
        try await send(type: "action_decision", payload: [
            "action_id": actionID.uuidString.lowercased(),
            "decision": "rejected",
            "action_hash": actionHash,
            "parameters_hash": parametersHash,
            "workspace_bookmark_id": workspaceBookmarkID,
            "expires_at": expiresAt,
        ])
    }

    private func run(generation: Int) async {
        var attempt = 0
        while !Task.isCancelled, generation == self.generation {
            do {
                setState(.discovering)
                let descriptor = try await bootstrap.ensureDaemonAvailable()
                do {
                    try descriptor.validate(supportedProtocol: Self.protocolVersion)
                } catch {
                    setState(.unsupportedProtocol)
                    return
                }
                setState(.connecting(attempt: attempt))
                let identity = try identities.loadOrCreate()
                let session = try await sessions.establish(
                    descriptor: descriptor,
                    installation: identity
                )
                guard generation == self.generation else {
                    session.socket.cancel()
                    return
                }
                self.descriptor = descriptor
                self.sessionToken = session.token
                self.socket = session.socket
                await MainActor.run {
                    self.installationID = identity.id
                }
                setState(.connected(instanceId: descriptor.instanceId))
                try await receive(session.socket, installationID: identity.id, generation: generation)
            } catch is CancellationError {
                return
            } catch LocalDaemonError.unsupportedProtocol {
                setState(.unsupportedProtocol)
                return
            } catch {
                setState(.offline(reason: error.localizedDescription))
            }
            attempt += 1
            let delay = min(30.0, pow(2.0, Double(min(attempt, 5))))
            try? await Task.sleep(for: .seconds(Double.random(in: 0...delay)))
        }
    }

    private func receive(
        _ socket: LocalDaemonSocket,
        installationID: String,
        generation: Int
    ) async throws {
        while !Task.isCancelled, generation == self.generation {
            let data = try await socket.receive()
            guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            let event: [String: Any]
            if envelope["type"] as? String == "event",
               let payload = envelope["payload"] as? [String: Any] {
                event = payload["data"] as? [String: Any] ?? payload
            } else {
                event = envelope
            }
            await MainActor.run {
                self.onEvent?(installationID, event)
            }
        }
    }

    private func setState(_ value: LocalDaemonConnectionState) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.state != value else { return }
            self.state = value
            self.onStateAnnouncement?(value.announcement)
        }
    }
}
