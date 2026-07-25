import CryptoKit
import Foundation
import XCTest
@testable import ExecutorCore
@testable import Perch

private actor CountingExecutionBackend: DeviceExecutionBackend {
    nonisolated let capabilityState: ExecutorCapabilityState = .available
    private var executions = 0
    let result: ExecutionResult

    init(result: ExecutionResult = ExecutionResult(
        status: .completed,
        exitCode: 0,
        stdout: "ok",
        stderr: "",
        truncated: false,
        durationMilliseconds: 12,
        redactions: 0
    )) {
        self.result = result
    }

    func execute(
        grantPayload: [String: Any],
        deviceID: String,
        userID: String
    ) async throws -> ExecutionResult {
        executions += 1
        return result
    }

    func cancel(actionID: String) async {}
    func count() -> Int { executions }
}

final class LocalExecutionIntegrationTests: XCTestCase {
    func testBookmarkIsSavedUnderExactIdentifierInInstallationPartition() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let accountData = AccountDataStore(rootURL: root)
        let store = ExecutorWorkspaceBookmarkStore(accountData: accountData)
        let installationID = UUID().uuidString.lowercased()
        let identifier = "action-\(UUID().uuidString.lowercased())"
        let data = Data("security-scoped-bookmark".utf8)

        try await store.save(data, identifier: identifier, userID: installationID)

        let saved = try await store.bookmark(
            identifier: identifier,
            userID: installationID
        )
        XCTAssertEqual(saved, data)
        let bookmarkFile = try accountData
            .installationDirectory(for: installationID)
            .appendingPathComponent("executor-workspaces.plist")
        XCTAssertTrue(FileManager.default.fileExists(atPath: bookmarkFile.path))
    }

    func testFingerprintAndSourceSealedManifestDigestAreExact() throws {
        let key = P256.Signing.PrivateKey().publicKey
        XCTAssertEqual(
            try ExecutorIPCAuthenticator.fingerprint(publicKeyPEM: key.pemRepresentation),
            SHA256.hash(data: key.derRepresentation)
                .map { String(format: "%02x", $0) }
                .joined()
        )

        let resource = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/ExecutorArtifacts.json")
        let data = try Data(contentsOf: resource)
        XCTAssertThrowsError(try ExecutorArtifactManifestVerifier().verify(data: data))
        let manifest = try ExecutorArtifactManifestVerifier().verify(
            data: data,
            mode: .enclosingBundleSeal
        )
        let installation = VerifiedExecutorInstallation(
            executable: URL(fileURLWithPath: "/sealed/Perch.app/Contents/Helpers/PerchExecutor"),
            manifest: manifest
        )
        XCTAssertEqual(
            installation.workloadImageDigest,
            "sha256:28a33e0390da2b341d05e53803c6766977039baedfc8a82a4910d5acc4755b66"
        )
    }

    func testMalformedAndStaleRequestsNeverExecute() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = CountingExecutionBackend()
        let processor = LocalExecutionRequestProcessor(
            backend: backend,
            accountData: AccountDataStore(rootURL: root)
        )
        let installationID = UUID().uuidString.lowercased()
        var malformed = request(installationID: installationID)
        malformed["unexpected"] = true
        await XCTAssertThrowsErrorAsync {
            _ = try await processor.handle(event: malformed, installationID: installationID)
        }

        let stale = request(
            installationID: installationID,
            expiresAt: Date().addingTimeInterval(-1)
        )
        let optionalResponse = try await processor.handle(
            event: stale,
            installationID: installationID
        )
        let response = try XCTUnwrap(optionalResponse)
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["status"] as? String, "failed")
        let staleExecutionCount = await backend.count()
        XCTAssertEqual(staleExecutionCount, 0)
    }

    func testRequestExecutesOnceAndTerminalResponseSurvivesProcessorRestart() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let accountData = AccountDataStore(rootURL: root)
        let backend = CountingExecutionBackend()
        let installationID = UUID().uuidString.lowercased()
        let event = request(installationID: installationID)
        let firstProcessor = LocalExecutionRequestProcessor(
            backend: backend,
            accountData: accountData
        )

        let firstOptional = try await firstProcessor.handle(
            event: event,
            installationID: installationID
        )
        let first = try XCTUnwrap(firstOptional)
        let secondProcessor = LocalExecutionRequestProcessor(
            backend: backend,
            accountData: accountData
        )
        let replayOptional = try await secondProcessor.handle(
            event: event,
            installationID: installationID
        )
        let replay = try XCTUnwrap(replayOptional)

        let executionCount = await backend.count()
        XCTAssertEqual(executionCount, 1)
        XCTAssertEqual(
            try canonical(first),
            try canonical(replay)
        )
        XCTAssertEqual(
            Set(first.keys),
            Set(["action_id", "request_id", "result"])
        )
        XCTAssertEqual(
            Set((first["result"] as! [String: Any]).keys),
            Set([
                "status", "exit_code", "stdout", "stderr", "truncated",
                "duration_ms", "redactions",
            ])
        )
    }

    func testResultOutputAndFailureDiagnosticsAreBounded() {
        let terminal = LocalExecutionTerminalResult(executionResult: ExecutionResult(
            status: .completed,
            exitCode: 0,
            stdout: String(repeating: "😀", count: 400_000),
            stderr: String(repeating: "e", count: 100),
            truncated: false,
            durationMilliseconds: 1,
            redactions: 0
        ))
        XCTAssertLessThanOrEqual(
            terminal.stdout.utf8.count + terminal.stderr.utf8.count,
            LocalExecutionTerminalResult.maximumCombinedOutputBytes
        )
        XCTAssertTrue(terminal.truncated)

        let failure = LocalExecutionTerminalResult(
            failure: NSError(
                domain: String(repeating: "x", count: 1_000),
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: String(repeating: "z", count: 2_000)]
            )
        )
        XCTAssertLessThanOrEqual(failure.stderr.utf8.count, 500)
        XCTAssertEqual(failure.error, failure.stderr)
    }

    func testAdHocNestedSignaturePolicyRequiresBothStrictSealsAndNoTeamIDs() {
        XCTAssertNoThrow(try ExecutorCodeSignaturePolicy.validate(.init(
            appStrictlyValid: true,
            executorStrictlyValid: true,
            executorHasVirtualizationEntitlement: true,
            executorIsNestedInSealedApp: true,
            appTeamID: nil,
            executorTeamID: nil
        )))
        XCTAssertNoThrow(try ExecutorCodeSignaturePolicy.validate(.init(
            appStrictlyValid: true,
            executorStrictlyValid: true,
            executorHasVirtualizationEntitlement: true,
            executorIsNestedInSealedApp: true,
            appTeamID: "TEAM",
            executorTeamID: "TEAM"
        )))
        XCTAssertThrowsError(try ExecutorCodeSignaturePolicy.validate(.init(
            appStrictlyValid: true,
            executorStrictlyValid: true,
            executorHasVirtualizationEntitlement: true,
            executorIsNestedInSealedApp: false,
            appTeamID: nil,
            executorTeamID: nil
        )))
        XCTAssertThrowsError(try ExecutorCodeSignaturePolicy.validate(.init(
            appStrictlyValid: true,
            executorStrictlyValid: true,
            executorHasVirtualizationEntitlement: true,
            executorIsNestedInSealedApp: true,
            appTeamID: "TEAM",
            executorTeamID: nil
        )))
    }

    private func request(
        installationID: String,
        expiresAt: Date = Date().addingTimeInterval(60)
    ) -> [String: Any] {
        let actionID = UUID().uuidString.lowercased()
        return [
            "type": "local_execution_request",
            "action_id": actionID,
            "request_id": UUID().uuidString.lowercased(),
            "grant": [
                "grant_id": UUID().uuidString.lowercased(),
                "action_id": actionID,
                "sequence": 1,
                "grant_token": String(repeating: "a", count: 43),
                "grant_signature": String(repeating: "b", count: 43),
                "action_hash": String(repeating: "c", count: 64),
                "parameters_hash": String(repeating: "d", count: 64),
                "registry_version": "1",
                "action_type": "workspace.inspect",
                "normalized_parameters": ["path": ".", "depth": 1],
                "capabilities": [
                    "workspace_mode": "read_only",
                    "egress_destinations": [],
                    "sensitive_file_access": false,
                    "sensitive_output_disclosure": false,
                    "result_upload": true,
                    "limits": [
                        "cpu_count": 1, "memory_bytes": 536_870_912,
                        "disk_bytes": 536_870_912, "process_count": 32,
                        "output_bytes": 65_536, "timeout_seconds": 30,
                    ],
                ],
                "image_digest": "sha256:" + String(repeating: "e", count: 64),
                "workspace_bookmark_id": "workspace-1",
                "result_disclosure_policy": [
                    "sensitive_output": false, "upload": true,
                ],
                "session_id": UUID().uuidString.lowercased(),
                "device_key_fingerprint": String(repeating: "f", count: 64),
                "device_id": installationID,
                "fence": 0,
                "expires_at": ISO8601DateFormatter().string(from: expiresAt),
                "transition_id": UUID().uuidString.lowercased(),
            ] as [String: Any],
        ]
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func canonical(_ value: [String: Any]) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: value,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {
        // Expected.
    }
}
