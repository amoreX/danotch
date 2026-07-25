import Foundation
import XCTest
@testable import Perch

private final class SecretTestKeychain: KeychainDataClient {
    var result: Result<Data, Error>

    init(_ result: Result<Data, Error>) {
        self.result = result
    }

    func read(service: String, account: String) throws -> Data {
        try result.get()
    }

    func add(_ data: Data, service: String, account: String) throws {}
    func update(_ data: Data, service: String, account: String) throws {}
    func delete(service: String, account: String) throws {}
}

private struct StubInstallationSecretReader: LocalInstallationSecretReading {
    let value: String

    func readInstallationSecret() throws -> LocalInstallationSecret {
        try LocalInstallationSecret(validatingBase64: value)
    }
}

private final class CapturingSessionURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let handler = Self.requestHandler else {
                throw URLError(.badServerResponse)
            }
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class LocalDaemonConnectionTests: XCTestCase {
    private func writeRuntime(_ json: String, to url: URL, permissions: Int = 0o600) throws {
        try json.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: permissions)],
            ofItemAtPath: url.path
        )
    }

    func testDiscoversValidatedLoopbackRuntimeDescriptor() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let runtime = root.appendingPathComponent("daemon.json")
        try writeRuntime("""
        {
          "port": 43123,
          "pid": 42,
          "protocolVersion": 1,
          "instanceId": "daemon-instance"
        }
        """, to: runtime)

        let descriptor = try RuntimeFileDaemonDiscovery(runtimeURL: runtime).discover()
        try descriptor.validate(supportedProtocol: 1)

        XCTAssertEqual(descriptor.baseURL.absoluteString, "http://127.0.0.1:43123")
        XCTAssertEqual(descriptor.instanceId, "daemon-instance")
    }

    func testRejectsInvalidOrUnsupportedRuntimeDescriptor() {
        let invalid = LocalDaemonRuntimeDescriptor(
            port: 0,
            pid: -1,
            protocolVersion: 1,
            instanceId: ""
        )
        XCTAssertThrowsError(try invalid.validate(supportedProtocol: 1))

        let unsupported = LocalDaemonRuntimeDescriptor(
            port: 43123,
            pid: 42,
            protocolVersion: 2,
            instanceId: "daemon-instance"
        )
        XCTAssertThrowsError(try unsupported.validate(supportedProtocol: 1))
    }

    func testDiscoveryRejectsUnsafeMetadataSizeAndUnexpectedKeys() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let runtime = root.appendingPathComponent("daemon.json")
        let valid = """
        {"port":43123,"pid":42,"protocolVersion":1,"instanceId":"daemon-instance"}
        """

        try writeRuntime(valid, to: runtime, permissions: 0o644)
        XCTAssertThrowsError(try RuntimeFileDaemonDiscovery(runtimeURL: runtime).discover())

        try writeRuntime(valid + String(repeating: " ", count: 4_096), to: runtime)
        XCTAssertThrowsError(try RuntimeFileDaemonDiscovery(runtimeURL: runtime).discover())

        try writeRuntime(
            """
            {"port":43123,"pid":42,"protocolVersion":1,"instanceId":"daemon-instance","extra":true}
            """,
            to: runtime
        )
        XCTAssertThrowsError(try RuntimeFileDaemonDiscovery(runtimeURL: runtime).discover())

        try FileManager.default.removeItem(at: runtime)
        let target = root.appendingPathComponent("target.json")
        try writeRuntime(valid, to: target)
        try FileManager.default.createSymbolicLink(at: runtime, withDestinationURL: target)
        XCTAssertThrowsError(try RuntimeFileDaemonDiscovery(runtimeURL: runtime).discover())
    }

    func testSecretReaderMapsMissingDeniedAndMalformedState() throws {
        XCTAssertThrowsError(
            try SecurityInstallationSecretReader(
                keychain: SecretTestKeychain(.failure(SecureStoreError.missing))
            ).readInstallationSecret()
        ) { error in
            XCTAssertEqual(error as? LocalDaemonError, .installationSecretMissing)
        }
        XCTAssertThrowsError(
            try SecurityInstallationSecretReader(
                keychain: SecretTestKeychain(.failure(SecureStoreError.interactionDenied))
            ).readInstallationSecret()
        ) { error in
            XCTAssertEqual(error as? LocalDaemonError, .installationSecretAccessDenied)
        }
        XCTAssertThrowsError(
            try SecurityInstallationSecretReader(
                keychain: SecretTestKeychain(.success(Data("not-base64".utf8)))
            ).readInstallationSecret()
        ) { error in
            XCTAssertEqual(error as? LocalDaemonError, .installationSecretMalformed)
        }
    }

    func testSessionRequestContainsInstallationSecretAndExpectedShape() async throws {
        let encodedSecret = Data(repeating: 0xA5, count: 32).base64EncodedString()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CapturingSessionURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let expectation = expectation(description: "Captured session request")

        CapturingSessionURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/v1/session")
            XCTAssertEqual(request.httpMethod, "POST")
            let body = try XCTUnwrap(request.httpBody)
            let json = try XCTUnwrap(
                JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            XCTAssertEqual(
                Set(json.keys),
                Set(["installation_id", "installation_secret", "instance_id", "protocol_versions"])
            )
            XCTAssertEqual(json["installation_id"] as? String, "installation-id")
            XCTAssertEqual(json["installation_secret"] as? String, encodedSecret)
            XCTAssertEqual(json["instance_id"] as? String, "daemon-instance")
            XCTAssertEqual(json["protocol_versions"] as? [Int], [1])
            expectation.fulfill()
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 401,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data()
            )
        }
        defer { CapturingSessionURLProtocol.requestHandler = nil }

        let establisher = URLSessionLocalDaemonSessionEstablisher(
            urlSession: session,
            secretReader: StubInstallationSecretReader(value: encodedSecret)
        )
        do {
            _ = try await establisher.establish(
                descriptor: LocalDaemonRuntimeDescriptor(
                    port: 43123,
                    pid: 42,
                    protocolVersion: 1,
                    instanceId: "daemon-instance"
                ),
                installation: LocalInstallationIdentity(
                    id: "installation-id",
                    createdAt: Date()
                )
            )
            XCTFail("Expected the stub 401 response to reject the session")
        } catch LocalDaemonError.sessionRejected {
            // Expected after request shape is captured.
        }
        await fulfillment(of: [expectation], timeout: 1)
    }

    func testInstallationIdentityIsStableAndPrivate() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalInstallationIdentityStore(rootURL: root)

        let first = try store.loadOrCreate()
        let second = try store.loadOrCreate()

        XCTAssertEqual(first, second)
        XCTAssertNotNil(UUID(uuidString: first.id))
        let attributes = try FileManager.default.attributesOfItem(
            atPath: root.appendingPathComponent("installation.json").path
        )
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testLegacyConversationImportIsIdempotentAndPinsInstallation() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let legacy = root.appendingPathComponent("legacy", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)

        let now = Date()
        let record = LocalConversationRecord(
            id: "conversation-1",
            title: "Imported",
            task: "Hello",
            status: .completed,
            createdAt: now,
            updatedAt: now,
            completedAt: now,
            toolCallsCount: 0,
            messages: [
                ChatMessage(
                    id: "message-1",
                    role: "user",
                    content: "Hello",
                    timestamp: now
                ),
            ],
            provider: "anthropic",
            modelId: "claude-sonnet-4-6"
        )
        struct File: Codable { let conversations: [LocalConversationRecord] }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(File(conversations: [record]))
            .write(to: legacy.appendingPathComponent("conversations.json"))

        let store = AccountDataStore(rootURL: support)
        try store.importLegacyConversations(
            installationID: "11111111-1111-4111-8111-111111111111",
            legacyDirectory: legacy
        )
        try store.importLegacyConversations(
            installationID: "11111111-1111-4111-8111-111111111111",
            legacyDirectory: legacy
        )

        let data = try Data(contentsOf: store.localConversationsURL(
            for: "11111111-1111-4111-8111-111111111111"
        ))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let imported = try decoder.decode(File.self, from: data)
        XCTAssertEqual(imported.conversations.map(\.id), ["conversation-1"])
        XCTAssertEqual(imported.conversations.first?.provider, "anthropic")
    }
}
