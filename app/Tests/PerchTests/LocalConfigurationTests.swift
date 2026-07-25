import Foundation
import XCTest
@testable import Perch

private final class CapturingUpdateLauncher: UpdateProcessLaunching {
    var executable: URL?
    var arguments: [String]?

    func launch(executable: URL, arguments: [String]) throws {
        self.executable = executable
        self.arguments = arguments
    }
}

final class LocalConfigurationTests: XCTestCase {
    @MainActor
    func testUpdaterLaunchesOnlyFixedInstalledCLICommand() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let executable = home.appendingPathComponent(".local/bin/perch")
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("#!/bin/sh\n".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: executable.path
        )
        let launcher = CapturingUpdateLauncher()
        let controller = UpdateController(homeDirectory: home, launcher: launcher)

        controller.checkForUpdates()

        XCTAssertEqual(launcher.executable, executable.standardizedFileURL)
        XCTAssertEqual(launcher.arguments, ["update"])
        XCTAssertEqual(controller.state, .launched)
    }

    @MainActor
    func testUpdaterShowsDocumentedInstructionWhenCLIIsMissing() {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let launcher = CapturingUpdateLauncher()
        let controller = UpdateController(homeDirectory: home, launcher: launcher)

        controller.checkForUpdates()

        XCTAssertEqual(
            controller.state,
            .unavailable(UpdateController.installInstruction)
        )
        XCTAssertNil(launcher.executable)
    }

    func testComposioMetadataResponseParsesAllLocalConfigurationFields() {
        let state = ComposioConfigState.parse([
            "configured": true,
            "connected_apps": ["gmail"],
            "local_user_id": "local-installation-user",
            "integrations": [
                [
                    "app_type": "gmail",
                    "display_name": "Gmail",
                    "auth_config_id": "gmail-auth",
                ],
                [
                    "app_type": "github",
                    "display_name": "GitHub",
                    "auth_config_id": NSNull(),
                ],
            ],
        ])

        XCTAssertTrue(state.configured)
        XCTAssertEqual(state.connectedApps, ["gmail"])
        XCTAssertEqual(state.localUserID, "local-installation-user")
        XCTAssertEqual(state.integrations, [
            .init(appType: "gmail", displayName: "Gmail", authConfigID: "gmail-auth"),
            .init(appType: "github", displayName: "GitHub", authConfigID: nil),
        ])
    }
}
