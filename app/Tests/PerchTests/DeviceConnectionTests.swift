import CryptoKit
import Foundation
import XCTest
#if canImport(ExecutorCore)
import ExecutorCore
#endif
@testable import Perch

final class FakeDeviceIdentity: DeviceSigningIdentity {
    var publicKey = DevicePublicKey(algorithm: "Ed25519", format: "spki-pem", value: "public")
    var deleted = false
    func sign(_ message: Data) throws -> Data { Data(repeating: 7, count: 64) }
    func delete() throws { deleted = true }
}

final class FakeDeviceIdentities: DeviceIdentityProviding {
    let value = FakeDeviceIdentity()
    var error: Error?
    func identity(for userID: String, createIfMissing: Bool) throws -> DeviceSigningIdentity {
        if let error { throw error }
        return value
    }
    func deleteIdentity(for userID: String) throws { try value.delete() }
}

final class FakeDeviceSocket: DeviceSocket {
    var messages: [Data] = []
    var sent: [Data] = []
    var cancelled = false
    var closeCode = 1000

    func receive() async throws -> Data {
        while messages.isEmpty && !cancelled {
            try await Task.sleep(for: .milliseconds(10))
        }
        if cancelled { throw CancellationError() }
        return messages.removeFirst()
    }
    func send(_ data: Data) async throws { sent.append(data) }
    func cancel() { cancelled = true }
}

final class FakeDeviceNetwork: DeviceConnectionNetwork {
    let socket = FakeDeviceSocket()
    var enrolledID = "10000000-0000-4000-8000-000000000001"
    var error: DeviceNetworkError?
    var enrollments = 0

    func challenge(token: String, purpose: String, deviceID: String?) async throws -> DeviceChallengeResponse {
        if let error { throw error }
        return DeviceChallengeResponse(challengeID: "challenge-\(purpose)", nonce: "nonce")
    }
    func enroll(
        token: String,
        challengeID: String,
        displayName: String,
        publicKey: DevicePublicKey,
        signature: String,
        replacementDeviceID: String?
    ) async throws -> EnrolledDeviceResponse {
        enrollments += 1
        return EnrolledDeviceResponse(device: .init(id: enrolledID))
    }
    func ticket(
        token: String,
        deviceID: String,
        challengeID: String,
        signature: String,
        versions: [Int]
    ) async throws -> DeviceTicketResponse {
        DeviceTicketResponse(ticket: "ticket", expiresAt: "2099-01-01T00:00:00Z", protocolVersion: 1)
    }
    func connect(ticket: String, protocolVersion: Int) async throws -> DeviceSocket { socket }
}

actor FakeExecutionBackend: DeviceExecutionBackend {
    nonisolated let capabilityState: ExecutorCapabilityState = .available
    private(set) var executions = 0
    func execute(
        grantPayload: [String: Any],
        deviceID: String,
        userID: String
    ) async throws -> ExecutionResult {
        executions += 1
        return ExecutionResult(
            status: .completed, exitCode: 0, stdout: "ok", stderr: "",
            truncated: false, durationMilliseconds: 1, redactions: 0
        )
    }
    func cancel(actionID: String) async {}
    func executionCount() -> Int { executions }
}

@MainActor
final class DeviceConnectionTests: XCTestCase {
    func testEnrollsThenConnectsAndPersistsDevice() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let data = AccountDataStore(rootURL: root)
        let network = FakeDeviceNetwork()
        let connection = DeviceConnection(
            network: network,
            identities: FakeDeviceIdentities(),
            accountData: data
        )
        connection.start(session: session("user-a"))

        try await waitUntil {
            if case .connected(let id) = connection.state { return id == network.enrolledID }
            return false
        }

        XCTAssertEqual(network.enrollments, 1)
        XCTAssertEqual(try data.loadDeviceState(for: "user-a").deviceID, network.enrolledID)
        connection.cancel()
    }

    func testRevocationAndUnsupportedProtocolReachTerminalStates() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let revokedNetwork = FakeDeviceNetwork()
        revokedNetwork.error = DeviceNetworkError(status: 404, code: "device_revoked", message: "Revoked")
        let connection = DeviceConnection(
            network: revokedNetwork,
            identities: FakeDeviceIdentities(),
            accountData: AccountDataStore(rootURL: root)
        )
        connection.start(session: session("user-a"))
        try await waitUntil {
            if case .revoked = connection.state { return true }
            return false
        }

        let unsupported = FakeDeviceNetwork()
        unsupported.error = DeviceNetworkError(status: 426, code: "unsupported_protocol", message: "Update")
        let second = DeviceConnection(
            network: unsupported,
            identities: FakeDeviceIdentities(),
            accountData: AccountDataStore(rootURL: root.appendingPathComponent("second"))
        )
        second.start(session: session("user-b"))
        try await waitUntil { second.state == .unsupportedProtocol }
        XCTAssertTrue(second.state.requiresUpdate)
        XCTAssertFalse(second.state.canRetry)
    }

    func testSecureEnclaveUnavailableShowsReenrollmentWithoutNetworkEnrollment() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let identities = FakeDeviceIdentities()
        identities.error = DeviceIdentityError.secureEnclaveUnavailable
        let network = FakeDeviceNetwork()
        let connection = DeviceConnection(
            network: network,
            identities: identities,
            accountData: AccountDataStore(rootURL: root)
        )
        connection.start(session: session("user-a"))

        try await waitUntil {
            if case .reenrollmentRequired(let reason) = connection.state {
                return reason.contains("Secure Enclave")
            }
            return false
        }
        XCTAssertEqual(network.enrollments, 0)
    }

    func testExecutionStartsOnlyAfterServerConsumesBoundGrant() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let network = FakeDeviceNetwork()
        let backend = FakeExecutionBackend()
        let data = AccountDataStore(rootURL: root)
        let connection = DeviceConnection(
            network: network,
            identities: FakeDeviceIdentities(),
            accountData: data,
            executionBackend: backend
        )
        var announcements: [String] = []
        connection.onStateAnnouncement = { announcements.append($0) }
        connection.start(session: session("user-executor"))
        try await waitUntil {
            if case .connected = connection.state { return true }
            return false
        }

        let actionID = "20000000-0000-4000-8000-000000000002"
        let grantID = "30000000-0000-4000-8000-000000000003"
        let sessionID = "80000000-0000-4000-8000-000000000008"
        let workspaceID = "workspace-test"
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let parameters: [String: Any] = ["path": "Sources", "depth": 2]
        let limits: [String: Any] = [
            "cpu_count": 1,
            "memory_bytes": 268_435_456,
            "disk_bytes": 536_870_912,
            "process_count": 32,
            "output_bytes": 65_536,
            "timeout_seconds": 30,
        ]
        let capabilitiesObject: [String: Any] = [
            "workspace_mode": "read_only",
            "egress_destinations": [],
            "sensitive_file_access": false,
            "sensitive_output_disclosure": false,
            "result_upload": false,
            "limits": limits,
        ]
        let executorParameters = try ExecutorJSON(any: parameters)
        let capabilities = try ExecutionCapabilities(
            json: ExecutorJSON(any: capabilitiesObject)
        )
        let parametersHash = LocalActionRegistry.shared.parametersHash(executorParameters)
        let actionHash = LocalActionRegistry.shared.actionHash(
            registryVersion: "1",
            name: "workspace.inspect",
            parameters: executorParameters
        )
        network.socket.messages.append(try JSONSerialization.data(withJSONObject: [
            "v": 1,
            "type": "reconnect_contract",
            "id": UUID().uuidString.lowercased(),
            "payload": [
                "cursor": 0,
                "replay_mode": "replay",
                "session_id": sessionID,
                "fence": 4,
            ],
        ]))
        try await Task.sleep(for: .milliseconds(40))
        try await connection.decideLocalAction(
            actionID: UUID(uuidString: actionID)!,
            actionHash: actionHash,
            parametersHash: parametersHash,
            capabilities: capabilities,
            workspaceURL: workspace,
            workspaceBookmarkID: workspaceID,
            highRiskShell: false,
            expiresAt: ISO8601DateFormatter().date(from: "2099-01-01T00:00:00Z")!,
            approved: true
        )
        let token = String(repeating: "x", count: 43)
        var grant: [String: Any] = [
            "grant_id": grantID,
            "action_id": actionID,
            "sequence": 1,
            "grant_token": token,
            "action_hash": actionHash,
            "parameters_hash": parametersHash,
            "registry_version": "1",
            "action_type": "workspace.inspect",
            "normalized_parameters": parameters,
            "capabilities": capabilitiesObject,
            "image_digest": "sha256:" + String(repeating: "c", count: 64),
            "workspace_bookmark_id": workspaceID,
            "result_disclosure_policy": [
                "sensitive_output": false,
                "upload": false,
            ],
            "session_id": sessionID,
            "device_key_fingerprint": String(repeating: "d", count: 64),
            "device_id": network.enrolledID,
            "fence": 4,
            "expires_at": "2099-01-01T00:00:00Z",
            "transition_id": "50000000-0000-4000-8000-000000000005",
        ]
        var signed: [String: Any] = [:]
        for field in ExecutionGrantAuthorization.signedFields {
            signed[field] = grant[field]!
        }
        let canonical = try JSONSerialization.data(
            withJSONObject: signed,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        grant["grant_signature"] = Data(HMAC<SHA256>.authenticationCode(
            for: canonical,
            using: SymmetricKey(data: Data(token.utf8))
        )).base64URLEncodedString
        XCTAssertNoThrow(try ExecutionGrantAuthorization().verify(payload: grant))
        network.socket.messages.append(try JSONSerialization.data(withJSONObject: [
            "v": 1,
            "type": "execution_grant",
            "id": "40000000-0000-4000-8000-000000000004",
            "payload": grant,
        ]))
        try await Task.sleep(for: .milliseconds(100))
        if network.socket.sent.count < 2 {
            XCTFail("grant claim failed: \(announcements)")
        }
        try await waitUntil { network.socket.sent.count >= 2 }
        let beforeConsumption = await backend.executionCount()
        XCTAssertEqual(beforeConsumption, 0)

        network.socket.messages.append(try JSONSerialization.data(withJSONObject: [
            "v": 1,
            "type": "grant_consumed",
            "id": "60000000-0000-4000-8000-000000000006",
            "payload": [
                "grant_id": grantID,
                "action_id": actionID,
                "transition_id": "70000000-0000-4000-8000-000000000007",
            ],
        ]))
        try await waitUntil { network.socket.sent.count >= 3 }
        let afterConsumption = await backend.executionCount()
        XCTAssertEqual(afterConsumption, 1)
        var persisted = try data.loadDeviceState(for: "user-executor")
        let pending = try XCTUnwrap(persisted.pendingResults.first)
        network.socket.messages.append(try JSONSerialization.data(withJSONObject: [
            "v": 1,
            "type": "result_ack",
            "id": pending.resultID,
            "payload": [
                "result_id": pending.resultID,
                "action_id": pending.actionID,
                "grant_id": pending.grantID,
            ],
        ]))
        try await waitUntil {
            (try? data.loadDeviceState(for: "user-executor").pendingResults.isEmpty) == true
        }
        persisted = try data.loadDeviceState(for: "user-executor")
        XCTAssertTrue(persisted.pendingResults.isEmpty)
        connection.cancel()
    }

    func testPersistedResultRetriesAfterAuthenticatedReconnect() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let data = AccountDataStore(rootURL: root)
        let result = PendingDeviceResult(
            resultID: "90000000-0000-4000-8000-000000000009",
            actionID: "20000000-0000-4000-8000-000000000002",
            grantID: "30000000-0000-4000-8000-000000000003",
            status: "completed",
            resultJSON: try JSONSerialization.data(
                withJSONObject: ["result_disclosed": false],
                options: [.sortedKeys]
            )
        )
        try data.saveDeviceState(
            DeviceAccountState(
                deviceID: nil,
                cursor: 0,
                processedTransitionIDs: [],
                pendingResults: [result]
            ),
            for: "retry-user"
        )
        let network = FakeDeviceNetwork()
        let connection = DeviceConnection(
            network: network,
            identities: FakeDeviceIdentities(),
            accountData: data,
            executionBackend: FakeExecutionBackend()
        )
        connection.start(session: session("retry-user"))
        try await waitUntil {
            if case .connected = connection.state { return true }
            return false
        }
        network.socket.messages.append(try JSONSerialization.data(withJSONObject: [
            "v": 1,
            "type": "reconnect_contract",
            "id": UUID().uuidString.lowercased(),
            "payload": [
                "cursor": 0,
                "replay_mode": "replay",
                "session_id": "80000000-0000-4000-8000-000000000008",
                "fence": 5,
            ],
        ]))
        try await waitUntil {
            network.socket.sent.contains { data in
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                return object?["type"] as? String == "action_result"
            }
        }
        XCTAssertEqual(
            try data.loadDeviceState(for: "retry-user").pendingResults,
            [result]
        )
        connection.cancel()
    }

    private func session(_ userID: String) -> AuthSession {
        AuthSession(
            accessToken: "access", refreshToken: "refresh", expiresAt: nil,
            userId: userID, email: "\(userID)@example.com", fullName: userID
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for connection state")
    }
}
