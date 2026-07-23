import XCTest
#if canImport(ExecutorCore)
@testable import ExecutorCore
#else
@testable import Perch
#endif

final class ExecutionConsentTests: XCTestCase {
    func testDisclosureNamesEveryElevatedCapability() throws {
        let disclosure = ExecutionConsentDisclosure(
            actionID: UUID(),
            actionName: "Run exact shell command",
            command: ["/bin/sh", "-lc", "curl https://example.com"],
            workspacePath: "/selected/project",
            workspaceMode: .readWrite,
            egressDestinations: ["example.com:443"],
            mayReadSensitiveFiles: true,
            sensitiveOutputMayLeaveDevice: true,
            resultWillBeUploaded: true,
            expiresAt: Date().addingTimeInterval(60)
        )
        XCTAssertTrue(disclosure.summary.contains("/bin/sh"))
        XCTAssertTrue(disclosure.summary.contains("/selected/project (read/write)"))
        XCTAssertTrue(disclosure.summary.contains("example.com:443"))
        XCTAssertTrue(disclosure.summary.contains("Sensitive output may be disclosed"))
        XCTAssertTrue(disclosure.summary.contains("Result leaves this Mac"))
    }

    func testApprovalIsParameterBoundAndSingleUse() async throws {
        let store = ExecutionConsentStore()
        let actionID = UUID()
        let caps = try capabilities(upload: false)
        let approval = ExecutionApproval(
            approvalID: UUID(),
            actionID: actionID,
            actionHash: String(repeating: "a", count: 64),
            parametersHash: String(repeating: "b", count: 64),
            capabilities: caps,
            workspaceBookmarkHash: String(repeating: "c", count: 64),
            approvedAt: Date(),
            expiresAt: Date().addingTimeInterval(60),
            highRiskShell: true
        )
        try await store.record(approval)
        _ = try await store.consume(
            actionID: actionID,
            actionHash: approval.actionHash,
            parametersHash: approval.parametersHash,
            capabilities: caps,
            workspaceBookmarkHash: approval.workspaceBookmarkHash,
            highRiskShell: true
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await store.consume(
                actionID: actionID,
                actionHash: approval.actionHash,
                parametersHash: approval.parametersHash,
                capabilities: caps,
                workspaceBookmarkHash: approval.workspaceBookmarkHash,
                highRiskShell: true
            )
        }
    }

    func testWriteEgressSensitiveAndUploadChangesCannotReuseApproval() throws {
        let policy = ConsentPolicy()
        let id = UUID()
        let old = try capabilities(upload: false)
        let prior = ExecutionApproval(
            approvalID: UUID(), actionID: id,
            actionHash: "a", parametersHash: "b", capabilities: old,
            workspaceBookmarkHash: "c", approvedAt: Date(),
            expiresAt: Date().addingTimeInterval(60), highRiskShell: false
        )
        XCTAssertTrue(policy.requiresFreshApproval(
            previous: prior,
            actionID: id,
            actionHash: "a",
            parametersHash: "b",
            capabilities: try capabilities(upload: true),
            workspaceBookmarkHash: "c",
            highRiskShell: false
        ))
    }

    private func capabilities(upload: Bool) throws -> ExecutionCapabilities {
        try ExecutionCapabilities(json: .object([
            "workspace_mode": .string("read_only"),
            "egress_destinations": .array([]),
            "sensitive_file_access": .boolean(false),
            "sensitive_output_disclosure": .boolean(false),
            "result_upload": .boolean(upload),
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
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {}
}
