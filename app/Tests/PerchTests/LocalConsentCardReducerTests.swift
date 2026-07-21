import Foundation
import XCTest
@testable import Perch

final class LocalConsentCardReducerTests: XCTestCase {
    func testElevationsRequireIndependentConfirmationsBeforeApproval() {
        var card = fixture(
            actionType: "shell.execute",
            workspaceMode: "read_write",
            sensitive: true,
            upload: true
        )
        let reducer = LocalConsentCardReducer()
        card = reducer.reduce(card, event: .selectedWorkspace("/tmp/project"))
        XCTAssertFalse(card.canApprove)
        for confirmation in LocalConsentConfirmation.allCases {
            card = reducer.reduce(card, event: .toggled(confirmation))
        }
        XCTAssertTrue(card.canApprove)
        card = reducer.reduce(card, event: .approve)
        XCTAssertEqual(card.state, .approving)
        XCTAssertFalse(card.canApprove)
    }

    func testNetworkRequestIsUnavailableAndCannotBeApproved() {
        var card = fixture(
            actionType: "workspace.inspect",
            workspaceMode: "read_only",
            sensitive: false,
            upload: false,
            egress: ["example.com:443"]
        )
        card.state = .unavailable
        let reducer = LocalConsentCardReducer()
        card = reducer.reduce(card, event: .selectedWorkspace("/tmp/project"))
        card = reducer.reduce(card, event: .approve)
        XCTAssertEqual(card.state, .unavailable)
        XCTAssertFalse(card.canApprove)
    }

    private func fixture(
        actionType: String,
        workspaceMode: String,
        sensitive: Bool,
        upload: Bool,
        egress: [String] = []
    ) -> LocalExecutionConsentCard {
        LocalExecutionConsentCard(
            actionID: UUID().uuidString,
            registryVersion: "1",
            actionType: actionType,
            actionHash: String(repeating: "a", count: 64),
            parametersHash: String(repeating: "b", count: 64),
            normalizedParametersJSON: Data("{}".utf8),
            capabilitiesJSON: Data("{}".utf8),
            workspaceBookmarkID: "workspace",
            command: ["/bin/true"],
            workspaceMode: workspaceMode,
            egressDestinations: egress,
            sensitiveFileAccess: sensitive,
            sensitiveDisclosure: sensitive,
            resultUpload: upload,
            expiresAt: Date().addingTimeInterval(60),
            selectedWorkspacePath: nil,
            confirmations: [],
            state: .pending,
            error: nil
        )
    }
}
