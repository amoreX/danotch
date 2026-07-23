import XCTest
@testable import Perch

final class OnboardingAuthTests: XCTestCase {
    func testVerificationLifecycleRepresentsCrossDeviceAndRepairStates() {
        XCTAssertEqual(AuthLifecycleState.credentials, .credentials)
        XCTAssertEqual(AuthLifecycleState.checkEmail("user@example.com"), .checkEmail("user@example.com"))
        XCTAssertEqual(
            AuthLifecycleState.crossDeviceVerified("user@example.com"),
            .crossDeviceVerified("user@example.com")
        )
        XCTAssertEqual(AuthLifecycleState.repairProvisioning, .repairProvisioning)
        XCTAssertNotEqual(
            AuthLifecycleState.verificationExpired("user@example.com"),
            .checkEmail("user@example.com")
        )
    }

    func testRefreshOnlyLogsOutForDefinitiveInvalidRefreshResponse() {
        XCTAssertEqual(
            RefreshFailureDisposition.classify(
                statusCode: 401,
                code: "invalid_refresh_token"
            ),
            .logout
        )
        XCTAssertEqual(
            RefreshFailureDisposition.classify(statusCode: 503, code: "refresh_unavailable"),
            .preserveSession
        )
        XCTAssertEqual(
            RefreshFailureDisposition.classify(statusCode: 429, code: "rate_limited"),
            .preserveSession
        )
        XCTAssertEqual(
            RefreshFailureDisposition.classify(statusCode: 200, code: nil),
            .preserveSession
        )
    }

    func testOnboardingUsesHostedBrowserSignupAndDoesNotExpectSignupTokens() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourcesDirectory = testsDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let authSource = try String(
            contentsOf: sourcesDirectory.appendingPathComponent("AuthManager.swift"),
            encoding: .utf8
        )
        let onboardingSource = try String(
            contentsOf: sourcesDirectory.appendingPathComponent("Views/OnboardingView.swift"),
            encoding: .utf8
        )
        let signupSource = authSource.components(separatedBy: "// MARK: - Login").first ?? authSource
        XCTAssertTrue(authSource.contains("/auth/signup/browser"))
        XCTAssertTrue(authSource.contains("NSWorkspace.shared.open(url)"))
        XCTAssertFalse(signupSource.contains("sessionObj"))
        XCTAssertTrue(onboardingSource.contains("Reopen signup"))
        XCTAssertTrue(onboardingSource.contains("I've verified"))
        XCTAssertTrue(onboardingSource.contains("Change email"))
    }
}
