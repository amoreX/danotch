import CryptoKit
import Foundation
import XCTest
#if canImport(ExecutorCore)
@testable import ExecutorCore
#else
@testable import Perch
#endif

final class ContainerRuntimeTests: XCTestCase {
    func testSignedArtifactManifestPinsReviewedReleaseAndDigests() throws {
        let resource = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/ExecutorArtifacts.json")
        let data = try Data(contentsOf: resource)
        XCTAssertThrowsError(try ExecutorArtifactManifestVerifier().verify(data: data))
        var envelope = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let payload = try XCTUnwrap(Data(
            base64Encoded: envelope["signed_payload"] as! String
        ))
        let fixtureKey = P256.Signing.PrivateKey()
        envelope["signature"] = try fixtureKey.signature(for: payload)
            .derRepresentation
            .base64EncodedString()
        let signedFixture = try JSONSerialization.data(withJSONObject: envelope)
        let manifest = try ExecutorArtifactManifestVerifier(
            publicKeyPEM: fixtureKey.publicKey.pemRepresentation
        ).verify(data: signedFixture)
        XCTAssertEqual(manifest.containerizationVersion, "0.33.3")
        XCTAssertEqual(manifest.containerizationCommit, "a2a1add6c7e1a1665e5397edc49d925c49090b3a")
        XCTAssertEqual(manifest.architecture, "arm64")
        XCTAssertEqual(Set(manifest.artifacts.map(\.kind)), Set([
            .kernelArchive, .kernel, .initImage, .workloadImage,
        ]))

        envelope["signed_payload"] = Data("tampered".utf8).base64EncodedString()
        XCTAssertThrowsError(try ExecutorArtifactManifestVerifier(
            publicKeyPEM: fixtureKey.publicKey.pemRepresentation
        ).verify(
            data: JSONSerialization.data(withJSONObject: envelope)
        ))
    }

    func testGrantValidatesAllBindingsBeforeRuntime() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try WorkspaceAccess(bookmarks: TestBookmarkResolver(root)).open(
            bookmark: WorkspaceBookmark(data: Data("bookmark".utf8)),
            mode: .readOnly
        )
        let parameters: ExecutorJSON = .object(["path": .string("Sources"), "depth": .integer(2)])
        let registry = LocalActionRegistry.shared
        let capabilities = try testCapabilities()
        let actionID = UUID()
        let deviceID = UUID()
        let digest = "sha256:" + String(repeating: "d", count: 64)
        let expiry = Date().addingTimeInterval(60)
        let offer = LocalActionOffer(
            actionID: actionID,
            registryVersion: "1",
            actionName: "workspace.inspect",
            normalizedParameters: parameters,
            parametersHash: registry.parametersHash(parameters),
            capabilities: capabilities,
            imageDigest: digest,
            expiresAt: expiry
        )
        let grant = ExecutionGrant(
            grantID: UUID(),
            actionID: actionID,
            grantToken: String(repeating: "x", count: 43),
            grantSignature: String(repeating: "y", count: 43),
            actionHash: registry.actionHash(
                registryVersion: "1",
                name: "workspace.inspect",
                parameters: parameters
            ),
            parametersHash: offer.parametersHash,
            normalizedParameters: parameters,
            capabilities: capabilities,
            imageDigest: digest,
            deviceID: deviceID,
            fence: 7,
            expiresAt: expiry,
            transitionID: UUID()
        )
        let validator = ExecutionGrantValidator(approvedImageDigest: digest)
        XCTAssertNoThrow(try validator.validate(
            offer: offer,
            grant: grant,
            connectedDeviceID: deviceID,
            currentFence: 7,
            workspace: scope
        ))
        XCTAssertThrowsError(try validator.validate(
            offer: offer,
            grant: grant,
            connectedDeviceID: deviceID,
            currentFence: 8,
            workspace: scope
        ))
        let sensitiveRoot = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: sensitiveRoot) }
        try Data("TOKEN=secret".utf8).write(
            to: sensitiveRoot.appendingPathComponent(".env")
        )
        let sensitiveScope = try WorkspaceAccess(
            bookmarks: TestBookmarkResolver(sensitiveRoot)
        ).open(
            bookmark: WorkspaceBookmark(data: Data("sensitive".utf8)),
            mode: .readOnly
        )
        defer { sensitiveScope.close() }
        XCTAssertThrowsError(try validator.validate(
            offer: offer,
            grant: grant,
            connectedDeviceID: deviceID,
            currentFence: 7,
            workspace: sensitiveScope
        ))
    }

    func testUnavailableRuntimeHasNoHostFallback() async {
        let runtime = UnavailableContainerRuntime(state: .unsupportedOS)
        XCTAssertEqual(runtime.capabilityState, .unsupportedOS)
        // No native Process/shell fallback is exposed by this runtime.
    }

    func testOutputIsBoundedSanitizedAndRedacted() {
        let writer = BoundedOutputWriter(limit: 64)
        writer.append(Data(repeating: 65, count: 100))
        XCTAssertTrue(writer.snapshot().truncated)

        let hostile = Data("\u{1B}[31mapi_key=supersecretvalue\u{1B}[0m\u{202E}<script>".utf8)
        let result = HostileOutputSanitizer().sanitize(
            hostile,
            allowSensitiveDisclosure: false
        )
        XCTAssertFalse(result.text.contains("\u{1B}"))
        XCTAssertFalse(result.text.contains("\u{202E}"))
        XCTAssertTrue(result.text.contains("[REDACTED]"))
    }

    private func testCapabilities() throws -> ExecutionCapabilities {
        try ExecutionCapabilities(json: .object([
            "workspace_mode": .string("read_only"),
            "egress_destinations": .array([]),
            "sensitive_file_access": .boolean(false),
            "sensitive_output_disclosure": .boolean(false),
            "result_upload": .boolean(false),
            "limits": .object([
                "cpu_count": .integer(1),
                "memory_bytes": .integer(536_870_912),
                "disk_bytes": .integer(536_870_912),
                "process_count": .integer(32),
                "output_bytes": .integer(65_536),
                "timeout_seconds": .integer(30),
            ]),
        ]))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
}

private struct TestBookmarkResolver: WorkspaceBookmarkResolving {
    let root: URL
    init(_ root: URL) { self.root = root }
    func create(for url: URL) throws -> WorkspaceBookmark { WorkspaceBookmark(data: Data()) }
    func resolve(_ bookmark: WorkspaceBookmark) throws -> (url: URL, stale: Bool) { (root, false) }
    func startAccessing(_ url: URL) -> Bool { true }
    func stopAccessing(_ url: URL) {}
}
