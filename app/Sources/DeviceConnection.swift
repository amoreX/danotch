import AppKit
import CryptoKit
#if canImport(ExecutorCore)
import ExecutorCore
#endif
import Foundation
import Network

enum DeviceConnectionState: Equatable {
    case signedOut
    case enrolling
    case connecting(attempt: Int)
    case connected(deviceID: String)
    case offline(reason: String)
    case expired
    case revoked(reason: String)
    case interrupted(reason: String)
    case reenrollmentRequired(reason: String)
    case unsupportedProtocol
    case cancelled

    var announcement: String {
        switch self {
        case .signedOut: return "Device connection signed out."
        case .enrolling: return "Enrolling this Mac."
        case .connecting(let attempt): return "Connecting this Mac. Attempt \(attempt + 1)."
        case .connected: return "This Mac is connected."
        case .offline(let reason): return "Device connection offline. \(reason)"
        case .expired: return "Device connection ticket expired. Retrying."
        case .revoked(let reason): return "This Mac was revoked. \(reason)"
        case .interrupted(let reason): return "Device connection interrupted. \(reason)"
        case .reenrollmentRequired(let reason): return "This Mac must be enrolled again. \(reason)"
        case .unsupportedProtocol: return "This version of Perch is not supported by the server."
        case .cancelled: return "Device connection cancelled."
        }
    }
}

struct DeviceChallengeResponse: Decodable {
    let challengeID: String
    let nonce: String

    enum CodingKeys: String, CodingKey {
        case challengeID = "challenge_id"
        case nonce
    }
}

struct EnrolledDeviceResponse: Decodable {
    struct Device: Decodable { let id: String }
    let device: Device
}

struct DeviceTicketResponse: Decodable {
    let ticket: String
    let expiresAt: String
    let protocolVersion: Int

    enum CodingKeys: String, CodingKey {
        case ticket
        case expiresAt = "expires_at"
        case protocolVersion = "protocol_version"
    }
}

protocol DeviceConnectionNetwork {
    func challenge(token: String, purpose: String, deviceID: String?) async throws -> DeviceChallengeResponse
    func enroll(
        token: String,
        challengeID: String,
        displayName: String,
        publicKey: DevicePublicKey,
        signature: String,
        replacementDeviceID: String?
    ) async throws -> EnrolledDeviceResponse
    func ticket(
        token: String,
        deviceID: String,
        challengeID: String,
        signature: String,
        versions: [Int]
    ) async throws -> DeviceTicketResponse
    func connect(ticket: String, protocolVersion: Int) async throws -> DeviceSocket
}

protocol DeviceSocket: AnyObject {
    func receive() async throws -> Data
    func send(_ data: Data) async throws
    func cancel()
    var closeCode: Int { get }
}

struct DeviceNetworkError: Error {
    let status: Int
    let code: String
    let message: String
}

final class URLSessionDeviceConnectionNetwork: DeviceConnectionNetwork {
    private let baseURL: URL
    private let gatewayURL: URL
    private let session: URLSession

    init(
        baseURL: URL = APIConfig.baseURLValue,
        gatewayURL: URL = APIConfig.gatewayURLValue,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.gatewayURL = gatewayURL
        self.session = session
    }

    func challenge(token: String, purpose: String, deviceID: String?) async throws -> DeviceChallengeResponse {
        var body: [String: Any] = ["purpose": purpose]
        if let deviceID { body["device_id"] = deviceID }
        return try await post("/api/devices/challenges", token: token, body: body)
    }

    func enroll(
        token: String,
        challengeID: String,
        displayName: String,
        publicKey: DevicePublicKey,
        signature: String,
        replacementDeviceID: String?
    ) async throws -> EnrolledDeviceResponse {
        var body: [String: Any] = [
            "challenge_id": challengeID,
            "display_name": displayName,
            "public_key": [
                "algorithm": publicKey.algorithm,
                "format": publicKey.format,
                "value": publicKey.value,
            ],
            "signature": signature,
        ]
        if let replacementDeviceID {
            body["replacement_device_id"] = replacementDeviceID
        }
        return try await post("/api/devices/enroll", token: token, body: body)
    }

    func ticket(
        token: String,
        deviceID: String,
        challengeID: String,
        signature: String,
        versions: [Int]
    ) async throws -> DeviceTicketResponse {
        try await post("/api/devices/\(deviceID)/tickets", token: token, body: [
            "challenge_id": challengeID,
            "signature": signature,
            "protocol_versions": versions,
        ])
    }

    func connect(ticket: String, protocolVersion: Int) async throws -> DeviceSocket {
        var request = URLRequest(url: gatewayURL)
        request.setValue("perch://app", forHTTPHeaderField: "Origin")
        let encodedTicket = Data(ticket.utf8).base64URLEncodedString
        request.setValue(
            "perch.v\(protocolVersion), perch-ticket.\(encodedTicket)",
            forHTTPHeaderField: "Sec-WebSocket-Protocol"
        )
        let task = session.webSocketTask(with: request)
        task.resume()
        return URLSessionDeviceSocket(task: task)
    }

    private func post<T: Decodable>(
        _ path: String,
        token: String,
        body: [String: Any]
    ) async throws -> T {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            let payload = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            throw DeviceNetworkError(
                status: status,
                code: payload["code"] as? String ?? "request_failed",
                message: payload["error"] as? String ?? "Request failed"
            )
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

private final class URLSessionDeviceSocket: DeviceSocket {
    private let task: URLSessionWebSocketTask
    init(task: URLSessionWebSocketTask) { self.task = task }

    var closeCode: Int { task.closeCode.rawValue }

    func receive() async throws -> Data {
        switch try await task.receive() {
        case .data(let data): return data
        case .string(let string): return Data(string.utf8)
        @unknown default: throw URLError(.cannotDecodeContentData)
        }
    }

    func send(_ data: Data) async throws {
        try await task.send(.data(data))
    }

    func cancel() {
        task.cancel(with: .goingAway, reason: nil)
    }
}

final class DeviceConnection: ObservableObject {
    static let protocolVersion = 1

    @Published private(set) var state: DeviceConnectionState = .signedOut
    @Published private(set) var activeUserID: String?

    var onEvent: ((String, [String: Any]) -> Void)?
    var onStateAnnouncement: ((String) -> Void)?

    private let network: DeviceConnectionNetwork
    private let identities: DeviceIdentityProviding
    private let accountData: AccountDataStore
    private let executionBackend: DeviceExecutionBackend
    private let workspaceBookmarks: ExecutorWorkspaceBookmarkStore
    private let executionConsent = ExecutionConsentStore()
    private var connectionTask: Task<Void, Never>?
    private weak var socket: DeviceSocket?
    private var generation = 0
    private var accessToken: String?
    private let pathMonitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "engineering.super.Perch.network-monitor")
    private var observers: [NSObjectProtocol] = []
    private var pendingExecutionGrants: [String: [String: Any]] = [:]
    private var executionTasks: [String: Task<Void, Never>] = [:]
    private var gatewaySessionID: String?
    private var gatewayFence: Int?

    init(
        network: DeviceConnectionNetwork = URLSessionDeviceConnectionNetwork(),
        identities: DeviceIdentityProviding = DeviceIdentityStore(),
        accountData: AccountDataStore = AccountDataStore(),
        executionBackend: DeviceExecutionBackend? = nil
    ) {
        self.network = network
        self.identities = identities
        self.accountData = accountData
        let workspaceBookmarks = ExecutorWorkspaceBookmarkStore(accountData: accountData)
        self.workspaceBookmarks = workspaceBookmarks
        self.executionBackend = executionBackend ?? ProductionExecutorBackend(
            identities: identities,
            bookmarks: workspaceBookmarks
        )
        observeLifecycle()
    }

    var executorCapabilityState: ExecutorCapabilityState {
        executionBackend.capabilityState
    }

    func saveWorkspaceBookmark(
        _ bookmark: Data,
        identifier: String,
        userID: String
    ) async throws {
        guard activeUserID == userID else {
            throw ExecutorIPCError.unauthenticated
        }
        try await workspaceBookmarks.save(bookmark, identifier: identifier, userID: userID)
    }

    func decideLocalAction(
        actionID: UUID,
        actionHash: String,
        parametersHash: String,
        capabilities: ExecutionCapabilities,
        workspaceURL: URL?,
        workspaceBookmarkID: String,
        highRiskShell: Bool,
        expiresAt: Date,
        approved: Bool
    ) async throws {
        guard let userID = activeUserID,
              let socket,
              gatewaySessionID != nil,
              gatewayFence != nil else {
            throw ExecutorIPCError.unauthenticated
        }
        if approved {
            guard capabilities.egressDestinations.isEmpty,
                  let workspaceURL else {
                throw LocalActionError.invalidBinding(
                    "network is unavailable or no workspace was selected"
                )
            }
            var options: URL.BookmarkCreationOptions = [.withSecurityScope]
            if capabilities.workspaceMode == .readOnly {
                options.insert(.securityScopeAllowOnlyReadAccess)
            }
            let bookmark = try workspaceURL.bookmarkData(
                options: options,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            try await workspaceBookmarks.save(
                bookmark,
                identifier: workspaceBookmarkID,
                userID: userID
            )
            try await executionConsent.record(ExecutionApproval(
                approvalID: UUID(),
                actionID: actionID,
                actionHash: actionHash,
                parametersHash: parametersHash,
                capabilities: capabilities,
                workspaceBookmarkHash: WorkspaceBookmark(data: bookmark).hash,
                approvedAt: Date(),
                expiresAt: expiresAt,
                highRiskShell: highRiskShell
            ))
        } else {
            await executionConsent.revoke(actionID: actionID)
        }
        let message: [String: Any] = [
            "v": Self.protocolVersion,
            "type": "action_decision",
            "id": UUID().uuidString.lowercased(),
            "payload": [
                "action_id": actionID.uuidString.lowercased(),
                "decision": approved ? "approved" : "rejected",
                "parameters_hash": parametersHash,
            ],
        ]
        try await socket.send(JSONSerialization.data(withJSONObject: message))
    }

    deinit {
        pathMonitor.cancel()
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func start(session: AuthSession) {
        cancel(markCancelled: false)
        generation += 1
        activeUserID = session.userId
        accessToken = session.accessToken
        let currentGeneration = generation
        connectionTask = Task { [weak self] in
            await self?.run(userID: session.userId, token: session.accessToken, generation: currentGeneration)
        }
    }

    func retry() {
        guard let userID = activeUserID, let token = accessToken else { return }
        cancel(markCancelled: false)
        generation += 1
        let currentGeneration = generation
        connectionTask = Task { [weak self] in
            await self?.run(userID: userID, token: token, generation: currentGeneration)
        }
    }

    func cancel(markCancelled: Bool = true) {
        generation += 1
        connectionTask?.cancel()
        connectionTask = nil
        executionTasks.values.forEach { $0.cancel() }
        executionTasks.removeAll()
        pendingExecutionGrants.removeAll()
        gatewaySessionID = nil
        gatewayFence = nil
        socket?.cancel()
        socket = nil
        if markCancelled { setState(.cancelled) }
    }

    func logout() {
        generation += 1
        connectionTask?.cancel()
        connectionTask = nil
        executionTasks.values.forEach { $0.cancel() }
        executionTasks.removeAll()
        pendingExecutionGrants.removeAll()
        gatewaySessionID = nil
        gatewayFence = nil
        let activeSocket = socket
        socket = nil
        activeUserID = nil
        accessToken = nil
        setState(.signedOut)
        Task {
            if let activeSocket {
                let logout: [String: Any] = [
                    "v": Self.protocolVersion,
                    "type": "logout",
                    "id": UUID().uuidString.lowercased(),
                    "payload": [:],
                ]
                if let data = try? JSONSerialization.data(withJSONObject: logout) {
                    try? await activeSocket.send(data)
                }
                activeSocket.cancel()
            }
        }
    }

    func reenroll() {
        guard let userID = activeUserID else { return }
        do {
            try identities.deleteIdentity(for: userID)
            var accountState = try accountData.loadDeviceState(for: userID)
            accountState.deviceID = nil
            accountState.deviceKeyAlgorithm = nil
            accountState.cursor = 0
            accountState.processedTransitionIDs = []
            try accountData.saveDeviceState(accountState, for: userID)
            retry()
        } catch {
            setState(.reenrollmentRequired(reason: error.localizedDescription))
        }
    }

    private func run(userID: String, token: String, generation: Int) async {
        var attempt = 0
        while !Task.isCancelled, generation == self.generation {
            do {
                var accountState = try accountData.loadDeviceState(for: userID)
                let identity = try identities.identity(for: userID, createIfMissing: true)
                let publicKey = try identity.publicKey
                let replacementDeviceID = accountState.deviceKeyAlgorithm == publicKey.algorithm
                    ? nil
                    : accountState.deviceID
                if replacementDeviceID != nil {
                    accountState.deviceID = nil
                    accountState.cursor = 0
                    accountState.processedTransitionIDs = []
                }
                if accountState.deviceID == nil {
                    setState(.enrolling)
                    let challenge = try await network.challenge(
                        token: token,
                        purpose: "enrollment",
                        deviceID: nil
                    )
                    let signature = try identity.sign(challengeMessage(
                        purpose: "enrollment",
                        challenge: challenge,
                        userID: userID,
                        deviceID: nil
                    )).base64URLEncodedString
                    let enrolled = try await network.enroll(
                        token: token,
                        challengeID: challenge.challengeID,
                        displayName: Host.current().localizedName ?? "Mac",
                        publicKey: publicKey,
                        signature: signature,
                        replacementDeviceID: replacementDeviceID
                    )
                    accountState.deviceID = enrolled.device.id
                    accountState.deviceKeyAlgorithm = publicKey.algorithm
                    try accountData.saveDeviceState(accountState, for: userID)
                }
                guard let deviceID = accountState.deviceID else { throw SecureStoreError.missing }
                setState(.connecting(attempt: attempt))
                let challenge = try await network.challenge(
                    token: token,
                    purpose: "ticket",
                    deviceID: deviceID
                )
                let signature = try identity.sign(challengeMessage(
                    purpose: "ticket",
                    challenge: challenge,
                    userID: userID,
                    deviceID: deviceID
                )).base64URLEncodedString
                let ticket = try await network.ticket(
                    token: token,
                    deviceID: deviceID,
                    challengeID: challenge.challengeID,
                    signature: signature,
                    versions: [Self.protocolVersion]
                )
                let connectedSocket = try await network.connect(
                    ticket: ticket.ticket,
                    protocolVersion: ticket.protocolVersion
                )
                guard generation == self.generation else {
                    connectedSocket.cancel()
                    return
                }
                socket = connectedSocket
                setState(.connected(deviceID: deviceID))
                attempt = 0
                try await receive(
                    socket: connectedSocket,
                    userID: userID,
                    deviceID: deviceID,
                    generation: generation
                )
                if Task.isCancelled { return }
                classifyClose(code: connectedSocket.closeCode)
            } catch is CancellationError {
                return
            } catch DeviceIdentityError.secureEnclaveUnavailable {
                setState(.reenrollmentRequired(
                    reason: "Secure Enclave is required to enroll this Mac."
                ))
                return
            } catch DeviceIdentityError.invalidStoredKey {
                setState(.reenrollmentRequired(
                    reason: "The hardware device key cannot be restored. Re-enrollment is required."
                ))
                return
            } catch let error as DeviceNetworkError {
                if error.status == 426 || error.code == "unsupported_protocol" {
                    setState(.unsupportedProtocol)
                    return
                }
                if error.code == "device_not_found" || error.code == "device_revoked" {
                    setState(.revoked(reason: error.message))
                    return
                }
                if error.code == "fresh_auth_required" {
                    setState(.reenrollmentRequired(reason: error.message))
                    return
                }
                if error.status == 401 {
                    setState(.expired)
                } else {
                    setState(.offline(reason: error.message))
                }
            } catch {
                setState(.interrupted(reason: error.localizedDescription))
            }
            attempt += 1
            let ceiling = min(30.0, pow(2.0, Double(min(attempt, 5))))
            try? await Task.sleep(for: .seconds(Double.random(in: 0...ceiling)))
        }
    }

    private func receive(
        socket: DeviceSocket,
        userID: String,
        deviceID: String,
        generation: Int
    ) async throws {
        while !Task.isCancelled, generation == self.generation {
            let data = try await socket.receive()
            guard generation == self.generation,
                  activeUserID == userID,
                  let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  envelope["v"] as? Int == Self.protocolVersion,
                  let type = envelope["type"] as? String,
                  let payload = envelope["payload"] as? [String: Any] else { continue }
            if type == "event" {
                try await handleEvent(
                    envelope: envelope,
                    payload: payload,
                    userID: userID,
                    deviceID: deviceID,
                    socket: socket
                )
            } else if type == "snapshot" {
                try handleSnapshot(payload, userID: userID)
            } else if type == "reconnect_contract" {
                // The persisted cursor remains authoritative. Reconnects use
                // the client's bounded full-jitter policy below.
                guard let sessionID = payload["session_id"] as? String,
                      UUID(uuidString: sessionID) != nil,
                      let fence = payload["fence"] as? Int,
                      fence >= 0 else {
                    throw LocalActionError.invalidBinding("gateway session binding")
                }
                gatewaySessionID = sessionID.lowercased()
                gatewayFence = fence
                try await retryPendingResults(
                    socket: socket,
                    userID: userID,
                    deviceID: deviceID
                )
            } else if type == "execution_grant" {
                try await claimExecutionGrant(payload, deviceID: deviceID, socket: socket)
            } else if type == "grant_consumed" {
                try await startConsumedExecution(payload, deviceID: deviceID, socket: socket)
            } else if type == "result_ack" {
                try acknowledgeResult(payload, userID: userID)
            }
        }
    }

    private func handleEvent(
        envelope: [String: Any],
        payload: [String: Any],
        userID: String,
        deviceID: String,
        socket: DeviceSocket
    ) async throws {
        guard let eventID = envelope["id"] as? String,
              let sequence = payload["sequence"] as? Int,
              let transitionID = payload["transition_id"] as? String,
              let eventType = payload["event_type"] as? String else { return }
        var state = try accountData.loadDeviceState(for: userID)
        if state.processedTransitionIDs.contains(transitionID) || sequence <= state.cursor {
            try await acknowledge(eventID: eventID, sequence: sequence, socket: socket)
            return
        }
        guard sequence == state.cursor + 1 else {
            throw DeviceNetworkError(status: 409, code: "cursor_gap", message: "Event replay has a cursor gap")
        }
        let data = payload["data"] as? [String: Any] ?? [:]
        if eventType == "cancellation_requested",
           let actionID = data["action_id"] as? String {
            executionTasks[actionID]?.cancel()
            await executionBackend.cancel(actionID: actionID)
        }
        var routed = data
        if routed["type"] == nil { routed["type"] = eventType }
        guard activeUserID == userID else { return }
        onEvent?(userID, routed)
        state.cursor = sequence
        state.processedTransitionIDs.append(transitionID)
        state.processedTransitionIDs = Array(state.processedTransitionIDs.suffix(500))
        try accountData.saveDeviceState(state, for: userID)
        try await acknowledge(eventID: eventID, sequence: sequence, socket: socket)
    }

    private func handleSnapshot(_ payload: [String: Any], userID: String) throws {
        guard let cursor = payload["cursor"] as? Int else { return }
        var state = try accountData.loadDeviceState(for: userID)
        state.cursor = cursor
        state.processedTransitionIDs = []
        try accountData.saveDeviceState(state, for: userID)
        if let snapshot = payload["snapshot"] as? [String: Any], activeUserID == userID {
            onEvent?(userID, ["type": "device_snapshot", "data": snapshot])
        }
    }

    private func acknowledge(eventID: String, sequence: Int, socket: DeviceSocket) async throws {
        let message: [String: Any] = [
            "v": Self.protocolVersion,
            "type": "ack",
            "id": UUID().uuidString.lowercased(),
            "payload": ["event_id": eventID, "sequence": sequence],
        ]
        try await socket.send(JSONSerialization.data(withJSONObject: message))
    }

    private func claimExecutionGrant(
        _ payload: [String: Any],
        deviceID: String,
        socket: DeviceSocket
    ) async throws {
        let required = Set([
            "grant_id", "action_id", "sequence", "grant_token", "grant_signature",
            "action_hash", "parameters_hash", "registry_version", "action_type",
            "normalized_parameters", "capabilities", "image_digest",
            "workspace_bookmark_id", "result_disclosure_policy", "session_id",
            "device_key_fingerprint", "device_id", "fence", "expires_at",
            "transition_id",
        ])
        guard Set(payload.keys) == required,
              payload["device_id"] as? String == deviceID,
              let grantID = payload["grant_id"] as? String,
              UUID(uuidString: grantID) != nil,
              let actionID = payload["action_id"] as? String,
              UUID(uuidString: actionID) != nil,
              let sessionID = payload["session_id"] as? String,
              sessionID.lowercased() == gatewaySessionID,
              let token = payload["grant_token"] as? String,
              token.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil,
              let actionHash = payload["action_hash"] as? String,
              actionHash.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              let parametersHash = payload["parameters_hash"] as? String,
              parametersHash.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              payload["normalized_parameters"] is [String: Any],
              payload["capabilities"] is [String: Any],
              let imageDigest = payload["image_digest"] as? String,
              imageDigest.range(of: "^sha256:[0-9a-f]{64}$", options: .regularExpression) != nil,
              let fence = payload["fence"] as? Int,
              fence >= 0,
              fence == gatewayFence,
              let expiry = payload["expires_at"] as? String,
              let expiresAt = ISO8601DateFormatter().date(from: expiry),
              expiresAt > Date() else {
            throw LocalActionError.invalidBinding("gateway grant schema, device, or expiry")
        }
        try ExecutionGrantAuthorization().verify(payload: payload)
        guard pendingExecutionGrants[grantID] == nil else { return }
        let parameters = try ExecutorJSON(any: payload["normalized_parameters"]!)
        let capabilities = try ExecutionCapabilities(
            json: ExecutorJSON(any: payload["capabilities"]!)
        )
        guard capabilities.egressDestinations.isEmpty,
              let registryVersion = payload["registry_version"] as? String,
              let actionType = payload["action_type"] as? String,
              LocalActionRegistry.shared.parametersHash(parameters) == parametersHash,
              LocalActionRegistry.shared.actionHash(
                registryVersion: registryVersion,
                name: actionType,
                parameters: parameters
              ) == actionHash,
              let disclosure = payload["result_disclosure_policy"] as? [String: Any],
              Set(disclosure.keys) == Set(["sensitive_output", "upload"]),
              (disclosure["sensitive_output"] as? Bool)
                == capabilities.sensitiveOutputDisclosure,
              (disclosure["upload"] as? Bool) == capabilities.resultUpload else {
            throw LocalActionError.invalidBinding("local action or disclosure binding")
        }
        let resolvedAction = try LocalActionRegistry.shared.resolve(
            registryVersion: registryVersion,
            name: actionType,
            parameters: parameters,
            capabilities: capabilities
        )
        _ = resolvedAction
        pendingExecutionGrants[grantID] = payload
        let consume: [String: Any] = [
            "v": Self.protocolVersion,
            "type": "consume_grant",
            "id": UUID().uuidString.lowercased(),
            "payload": [
                "action_id": actionID,
                "grant_id": grantID,
                "grant_token": token,
                "grant_signature": payload["grant_signature"]!,
                "action_hash": actionHash,
                "parameters_hash": parametersHash,
                "registry_version": registryVersion,
                "action_type": actionType,
                "normalized_parameters": payload["normalized_parameters"]!,
                "capabilities": payload["capabilities"]!,
                "image_digest": imageDigest,
                "workspace_bookmark_id": payload["workspace_bookmark_id"]!,
                "result_disclosure_policy": payload["result_disclosure_policy"]!,
                "session_id": sessionID,
                "device_key_fingerprint": payload["device_key_fingerprint"]!,
                "expires_at": expiry,
                "transition_id": payload["transition_id"]!,
            ],
        ]
        try await socket.send(JSONSerialization.data(withJSONObject: consume))
    }

    private func startConsumedExecution(
        _ payload: [String: Any],
        deviceID: String,
        socket: DeviceSocket
    ) async throws {
        guard Set(payload.keys) == Set(["grant_id", "action_id", "transition_id"]),
              let grantID = payload["grant_id"] as? String,
              let actionID = payload["action_id"] as? String,
              let grant = pendingExecutionGrants.removeValue(forKey: grantID),
              grant["action_id"] as? String == actionID,
              executionTasks[actionID] == nil else {
            return
        }
        guard let userID = activeUserID else {
            throw ExecutorIPCError.unauthenticated
        }
        try await consumeApproval(for: grant, userID: userID)
        let task = Task { [weak self, weak socket] in
            guard let self, let socket else { return }
            let status: String
            let result: [String: Any]
            do {
                let execution = try await self.executionBackend.execute(
                    grantPayload: grant,
                    deviceID: deviceID,
                    userID: userID
                )
                status = execution.status.rawValue
                let mayUpload = ((grant["capabilities"] as? [String: Any])?["result_upload"] as? Bool) == true
                result = mayUpload
                    ? execution.protocolObject
                    : [
                        "result_disclosed": false,
                        "exit_code": execution.exitCode.map { Int($0) as Any } ?? NSNull(),
                        "truncated": execution.truncated,
                        "redactions": execution.redactions,
                    ]
            } catch is CancellationError {
                status = "cancelled"
                result = ["code": "cancelled"]
            } catch {
                status = "failed"
                result = ["code": "local_execution_failed"]
            }
            if self.activeUserID == userID {
                do {
                    let bounded = try self.boundedResult(result)
                    let pending = PendingDeviceResult(
                        resultID: UUID().uuidString.lowercased(),
                        actionID: actionID,
                        grantID: grantID,
                        status: status,
                        resultJSON: bounded
                    )
                    var state = try self.accountData.loadDeviceState(for: userID)
                    if !state.pendingResults.contains(where: { $0.resultID == pending.resultID }) {
                        state.pendingResults.append(pending)
                        try self.accountData.saveDeviceState(state, for: userID)
                    }
                    try await self.sendPendingResult(
                        pending,
                        socket: socket,
                        userID: userID,
                        deviceID: deviceID
                    )
                } catch {
                    // The persisted result remains queued and is retried after
                    // the next authenticated reconnect contract.
                }
            }
            self.executionTasks.removeValue(forKey: actionID)
        }
        executionTasks[actionID] = task
    }

    private func consumeApproval(
        for grant: [String: Any],
        userID: String
    ) async throws {
        guard let actionValue = grant["action_id"] as? String,
              let actionID = UUID(uuidString: actionValue),
              let actionHash = grant["action_hash"] as? String,
              let parametersHash = grant["parameters_hash"] as? String,
              let registryVersion = grant["registry_version"] as? String,
              let actionType = grant["action_type"] as? String,
              let bookmarkID = grant["workspace_bookmark_id"] as? String,
              let rawParameters = grant["normalized_parameters"],
              let rawCapabilities = grant["capabilities"] else {
            throw LocalActionError.invalidBinding("approval workspace binding")
        }
        let parameters = try ExecutorJSON(any: rawParameters)
        let capabilities = try ExecutionCapabilities(
            json: ExecutorJSON(any: rawCapabilities)
        )
        let action = try LocalActionRegistry.shared.resolve(
            registryVersion: registryVersion,
            name: actionType,
            parameters: parameters,
            capabilities: capabilities
        )
        let bookmark = try await workspaceBookmarks.bookmark(
            identifier: bookmarkID,
            userID: userID
        )
        _ = try await executionConsent.consume(
            actionID: actionID,
            actionHash: actionHash,
            parametersHash: parametersHash,
            capabilities: capabilities,
            workspaceBookmarkHash: WorkspaceBookmark(data: bookmark).hash,
            highRiskShell: action.highRiskShell
        )
    }

    private func retryPendingResults(
        socket: DeviceSocket,
        userID: String,
        deviceID: String
    ) async throws {
        let state = try accountData.loadDeviceState(for: userID)
        for pending in state.pendingResults {
            try await sendPendingResult(
                pending,
                socket: socket,
                userID: userID,
                deviceID: deviceID
            )
        }
    }

    private func sendPendingResult(
        _ pending: PendingDeviceResult,
        socket: DeviceSocket,
        userID: String,
        deviceID: String
    ) async throws {
        guard let sessionID = gatewaySessionID,
              let fence = gatewayFence,
              let result = try JSONSerialization.jsonObject(
                with: pending.resultJSON
              ) as? [String: Any] else {
            throw ExecutorIPCError.unauthenticated
        }
        let hash = SHA256.hash(data: pending.resultJSON)
            .map { String(format: "%02x", $0) }
            .joined()
        let signingPayload = Data([
            "perch-action-result",
            String(Self.protocolVersion),
            pending.resultID.lowercased(),
            deviceID.lowercased(),
            sessionID.lowercased(),
            String(fence),
            pending.actionID.lowercased(),
            pending.grantID.lowercased(),
            pending.status,
            hash,
        ].joined(separator: "\n").utf8)
        let identity = try identities.identity(for: userID, createIfMissing: false)
        let signature = try identity.sign(signingPayload).base64URLEncodedString
        let message: [String: Any] = [
            "v": Self.protocolVersion,
            "type": "action_result",
            "id": pending.resultID,
            "payload": [
                "action_id": pending.actionID,
                "grant_id": pending.grantID,
                "status": pending.status,
                "result": result,
                "session_id": sessionID,
                "signature": signature,
            ],
        ]
        let encoded = try JSONSerialization.data(withJSONObject: message)
        guard encoded.count <= 64 * 1_024 else { throw ExecutorIPCError.oversized }
        try await socket.send(encoded)
    }

    private func acknowledgeResult(_ payload: [String: Any], userID: String) throws {
        guard Set(payload.keys) == Set(["result_id", "action_id", "grant_id"]),
              let resultID = payload["result_id"] as? String,
              let actionID = payload["action_id"] as? String,
              let grantID = payload["grant_id"] as? String else {
            throw ExecutorIPCError.malformed
        }
        var state = try accountData.loadDeviceState(for: userID)
        guard let pending = state.pendingResults.first(where: { $0.resultID == resultID }),
              pending.actionID == actionID,
              pending.grantID == grantID else {
            return
        }
        state.pendingResults.removeAll { $0.resultID == resultID }
        try accountData.saveDeviceState(state, for: userID)
    }

    private func boundedResult(_ result: [String: Any]) throws -> Data {
        var bounded = result
        var encoded = try JSONSerialization.data(
            withJSONObject: bounded,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        if encoded.count > 48 * 1_024 {
            for key in ["stdout", "stderr"] {
                if let text = bounded[key] as? String {
                    bounded[key] = String(
                        decoding: Data(text.utf8.prefix(16 * 1_024)),
                        as: UTF8.self
                    )
                }
            }
            bounded["truncated"] = true
            encoded = try JSONSerialization.data(
                withJSONObject: bounded,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
        }
        guard encoded.count <= 48 * 1_024 else { throw ExecutorIPCError.oversized }
        return encoded
    }

    private func challengeMessage(
        purpose: String,
        challenge: DeviceChallengeResponse,
        userID: String,
        deviceID: String?
    ) -> Data {
        Data([
            "perch-device-challenge", "1", purpose, challenge.challengeID,
            challenge.nonce, userID, deviceID ?? "new",
        ].joined(separator: ":").utf8)
    }

    private func classifyClose(code: Int) {
        switch code {
        case 4002, 4008: setState(.revoked(reason: "The server fenced this device session."))
        case 4003, 426: setState(.unsupportedProtocol)
        case 4006: setState(.interrupted(reason: "Heartbeat timed out."))
        default: setState(.interrupted(reason: "The secure connection closed."))
        }
    }

    private func setState(_ newState: DeviceConnectionState) {
        guard state != newState else { return }
        state = newState
        onStateAnnouncement?(newState.announcement)
    }

    private func observeLifecycle() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else {
                Task { @MainActor [weak self] in
                    self?.setState(.offline(reason: "Network unavailable."))
                }
                return
            }
            Task { @MainActor [weak self] in
                guard let self, self.activeUserID != nil,
                      case .offline = self.state else { return }
                self.retry()
            }
        }
        pathMonitor.start(queue: monitorQueue)
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.cancel(markCancelled: false)
                self?.setState(.interrupted(reason: "Mac went to sleep."))
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.retry() }
        })
    }
}
