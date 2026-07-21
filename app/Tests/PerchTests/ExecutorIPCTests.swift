import CryptoKit
import Foundation
import XCTest
#if canImport(ExecutorCore)
@testable import ExecutorCore
#else
@testable import Perch
#endif

final class ExecutorIPCTests: XCTestCase {
    func testAuthenticatedRequestBindsDeviceSessionFenceAndGrant() throws {
        let fixture = try requestFixture()
        let decoded = try ExecutorIPCRequest.decode(JSONEncoder().encode(fixture.request))
        let grant = try ExecutorIPCAuthenticator().verify(decoded)
        XCTAssertEqual(grant["action_id"] as? String, fixture.actionID.uuidString.lowercased())
        XCTAssertNoThrow(try ExecutionGrantAuthorization().verify(payload: grant))

        let staleFence = ExecutorIPCRequest(
            requestID: fixture.request.requestID,
            sessionID: fixture.request.sessionID,
            deviceID: fixture.request.deviceID,
            fence: fixture.request.fence + 1,
            grantJSON: fixture.request.grantJSON,
            workspaceBookmark: fixture.request.workspaceBookmark,
            devicePublicKeyPEM: fixture.request.devicePublicKeyPEM,
            ipcSecret: fixture.request.ipcSecret,
            signatureDER: fixture.request.signatureDER
        )
        XCTAssertThrowsError(try ExecutorIPCAuthenticator().verify(staleFence))
    }

    func testMalformedOversizedAndUnknownMessagesAreRejected() throws {
        let fixture = try requestFixture()
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(fixture.request))
                as? [String: Any]
        )
        object["unexpected"] = true
        XCTAssertThrowsError(try ExecutorIPCRequest.decode(
            JSONSerialization.data(withJSONObject: object)
        ))
        object.removeValue(forKey: "unexpected")
        object["type"] = "native_shell"
        XCTAssertThrowsError(try ExecutorIPCRequest.decode(
            JSONSerialization.data(withJSONObject: object)
        ))
        XCTAssertThrowsError(try ExecutorIPCRequest.decode(
            Data(repeating: 0, count: ExecutorIPCRequest.maximumBytes + 1)
        ))
    }

    func testReplayGuardClaimsRequestAndGrantOnlyOnce() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let guardStore = ExecutorIPCReplayGuard(root: root)
        let requestID = UUID()
        let grantID = UUID()
        XCTAssertNoThrow(try guardStore.claim(requestID: requestID, grantID: grantID))
        XCTAssertThrowsError(try guardStore.claim(requestID: requestID, grantID: grantID)) {
            XCTAssertEqual($0 as? ExecutorIPCError, .replay)
        }
    }

    func testResponseAuthenticationRejectsTampering() throws {
        let secret = Data(repeating: 9, count: 32)
        let requestID = UUID()
        let response = try ExecutorIPCResponse(
            requestID: requestID,
            resultJSON: Data(#"{"status":"completed"}"#.utf8),
            ipcSecret: secret
        )
        XCTAssertNoThrow(try response.verify(
            ipcSecret: secret,
            expectedRequestID: requestID
        ))
        XCTAssertThrowsError(try response.verify(
            ipcSecret: Data(repeating: 8, count: 32),
            expectedRequestID: requestID
        ))
    }

    private func requestFixture() throws -> (
        request: ExecutorIPCRequest,
        actionID: UUID
    ) {
        let key = P256.Signing.PrivateKey()
        let deviceID = UUID()
        let sessionID = UUID()
        let actionID = UUID()
        let grantID = UUID()
        let transitionID = UUID()
        let token = String(repeating: "x", count: 43)
        let fingerprint = SHA256.hash(data: key.publicKey.derRepresentation)
            .map { String(format: "%02x", $0) }
            .joined()
        var grant: [String: Any] = [
            "grant_id": grantID.uuidString.lowercased(),
            "action_id": actionID.uuidString.lowercased(),
            "action_hash": String(repeating: "a", count: 64),
            "parameters_hash": String(repeating: "b", count: 64),
            "registry_version": "1",
            "action_type": "workspace.inspect",
            "normalized_parameters": ["path": "Sources", "depth": 2],
            "capabilities": [:],
            "image_digest": "sha256:" + String(repeating: "c", count: 64),
            "workspace_bookmark_id": "workspace-test",
            "result_disclosure_policy": [
                "sensitive_output": false,
                "upload": false,
            ],
            "session_id": sessionID.uuidString.lowercased(),
            "device_key_fingerprint": fingerprint,
            "device_id": deviceID.uuidString.lowercased(),
            "fence": 7,
            "expires_at": "2099-01-01T00:00:00Z",
            "transition_id": transitionID.uuidString.lowercased(),
            "grant_token": token,
            "sequence": 1,
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
        )).base64URL
        let grantJSON = try JSONSerialization.data(
            withJSONObject: grant,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        let unsigned = ExecutorIPCRequest(
            requestID: UUID(),
            sessionID: sessionID,
            deviceID: deviceID,
            fence: 7,
            grantJSON: grantJSON,
            workspaceBookmark: Data("bookmark".utf8),
            devicePublicKeyPEM: key.publicKey.pemRepresentation,
            ipcSecret: Data(repeating: 4, count: 32),
            signatureDER: Data([0x30, 0x00])
        )
        let request = ExecutorIPCRequest(
            requestID: unsigned.requestID,
            sessionID: sessionID,
            deviceID: deviceID,
            fence: 7,
            grantJSON: grantJSON,
            workspaceBookmark: unsigned.workspaceBookmark,
            devicePublicKeyPEM: key.publicKey.pemRepresentation,
            ipcSecret: unsigned.ipcSecret,
            signatureDER: try key.signature(for: unsigned.signingData()).derRepresentation
        )
        return (request, actionID)
    }
}

private extension Data {
    var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
