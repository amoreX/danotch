import Foundation
import XCTest
@testable import Perch

@MainActor
final class EventRoutingTests: XCTestCase {
    func testReplayDeduplicatesAndAccountSwitchFencesLateEvents() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let accountData = AccountDataStore(rootURL: root)
        let deviceID = "10000000-0000-4000-8000-000000000001"
        try accountData.saveDeviceState(
            DeviceAccountState(deviceID: deviceID, cursor: 0, processedTransitionIDs: []),
            for: "user-a"
        )
        let network = FakeDeviceNetwork()
        let eventID = "20000000-0000-4000-8000-000000000002"
        let transitionID = "30000000-0000-4000-8000-000000000003"
        network.socket.messages = [
            try envelope(
                eventID: eventID,
                transitionID: transitionID,
                sequence: 1,
                data: ["type": "notification", "data": ["id": "n1", "title": "A"]]
            ),
            try envelope(
                eventID: eventID,
                transitionID: transitionID,
                sequence: 1,
                data: ["type": "notification", "data": ["id": "n1", "title": "A"]]
            ),
        ]
        let connection = DeviceConnection(
            network: network,
            identities: FakeDeviceIdentities(),
            accountData: accountData
        )
        var routed: [(String, String)] = []
        connection.onEvent = { userID, value in
            routed.append((userID, value["type"] as? String ?? ""))
        }
        connection.start(session: session("user-a"))

        try await waitUntil { network.socket.sent.count == 2 }

        XCTAssertEqual(routed.count, 1)
        XCTAssertEqual(routed.first?.0, "user-a")
        XCTAssertEqual(try accountData.loadDeviceState(for: "user-a").cursor, 1)

        connection.logout()
        network.socket.messages.append(try envelope(
            eventID: "40000000-0000-4000-8000-000000000004",
            transitionID: "50000000-0000-4000-8000-000000000005",
            sequence: 2,
            data: ["type": "notification"]
        ))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(routed.count, 1)
    }

    private func envelope(
        eventID: String,
        transitionID: String,
        sequence: Int,
        data: [String: Any]
    ) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "v": 1,
            "type": "event",
            "id": eventID,
            "payload": [
                "sequence": sequence,
                "transition_id": transitionID,
                "event_type": "notification",
                "data": data,
            ],
        ])
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
        XCTFail("Timed out waiting for routed events")
    }
}
