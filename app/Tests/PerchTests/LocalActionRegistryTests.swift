import XCTest
#if canImport(ExecutorCore)
@testable import ExecutorCore
#else
@testable import Perch
#endif

final class LocalActionRegistryTests: XCTestCase {
    func testTypedActionRequiresExactVersionAndSchema() throws {
        let registry = LocalActionRegistry.shared
        let parameters: ExecutorJSON = .object([
            "path": .string("Sources"),
            "depth": .integer(3),
        ])
        let action = try registry.resolve(
            registryVersion: "1",
            name: "workspace.inspect",
            parameters: parameters,
            capabilities: try capabilities()
        )
        XCTAssertEqual(action.executable, "/usr/bin/find")
        XCTAssertEqual(action.arguments, ["Sources", "-xdev", "-maxdepth", "3", "-print"])
        let sharedFixture: ExecutorJSON = .object([
            "path": .string("Sources"),
            "depth": .integer(2),
        ])
        XCTAssertEqual(
            registry.parametersHash(sharedFixture),
            "07bbaf1d3aee2c0305e15e7af82c5604d48ef7c27c056e33ad3be2874a9b1ff7"
        )
        XCTAssertEqual(
            registry.actionHash(
                registryVersion: "1",
                name: "workspace.inspect",
                parameters: sharedFixture
            ),
            "0e17134b73b690ce8a5eafbe33b013ebe8e2e657211b3527c3a85ccbf45d4a70"
        )

        XCTAssertThrowsError(try registry.resolve(
            registryVersion: "2",
            name: "workspace.inspect",
            parameters: parameters,
            capabilities: capabilities()
        ))
        XCTAssertThrowsError(try registry.resolve(
            registryVersion: "1",
            name: "workspace.inspect",
            parameters: .object([
                "path": .string("Sources"),
                "depth": .integer(3),
                "unexpected": .boolean(true),
            ]),
            capabilities: capabilities()
        ))
    }

    func testShellIsSeparateHighRiskExactCommand() throws {
        let command = "printf '%s' \"$HOME\""
        let action = try LocalActionRegistry.shared.resolve(
            registryVersion: "1",
            name: "shell.execute",
            parameters: .object(["command": .string(command)]),
            capabilities: capabilities()
        )
        XCTAssertTrue(action.highRiskShell)
        XCTAssertEqual(action.arguments, ["-lc", command])
        XCTAssertThrowsError(try LocalActionRegistry.shared.resolve(
            registryVersion: "1",
            name: "shell.execute",
            parameters: .object(["command": .string(command), "cwd": .string("/")]),
            capabilities: capabilities()
        ))
    }

    func testCapabilitiesDenyWildcardsAndBoundResources() {
        XCTAssertThrowsError(try ExecutionCapabilities(json: .object([
            "workspace_mode": .string("read_only"),
            "egress_destinations": .array([.string("*.example.com:443")]),
            "sensitive_file_access": .boolean(false),
            "sensitive_output_disclosure": .boolean(false),
            "result_upload": .boolean(false),
            "limits": limitsJSON(),
        ])))
        var excessive = limitsJSON()
        if case .object(var values) = excessive {
            values["memory_bytes"] = .integer(16 * 1_024 * 1_024 * 1_024)
            excessive = .object(values)
        }
        XCTAssertThrowsError(try ExecutionLimits(json: excessive))
    }

    private func capabilities() throws -> ExecutionCapabilities {
        try ExecutionCapabilities(json: .object([
            "workspace_mode": .string("read_only"),
            "egress_destinations": .array([]),
            "sensitive_file_access": .boolean(false),
            "sensitive_output_disclosure": .boolean(false),
            "result_upload": .boolean(false),
            "limits": limitsJSON(),
        ]))
    }

    private func limitsJSON() -> ExecutorJSON {
        .object([
            "cpu_count": .integer(2),
            "memory_bytes": .integer(1_073_741_824),
            "disk_bytes": .integer(2_147_483_648),
            "process_count": .integer(64),
            "output_bytes": .integer(1_048_576),
            "timeout_seconds": .integer(300),
        ])
    }
}
