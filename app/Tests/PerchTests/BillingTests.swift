import Foundation
import XCTest
@testable import Perch

final class BillingTests: XCTestCase {
    private let validStatus = """
    {
      "userId": "user-1",
      "billingStatus": "trialing",
      "trialStartedAt": "2026-01-01T00:00:00.000Z",
      "trialEndsAt": "2099-01-15T00:00:00.000Z",
      "trialDaysRemaining": 14,
      "lifetimePurchasedAt": null,
      "hasActiveProvider": false,
      "activeProvider": null,
      "canUseServerKey": true,
      "requiresPurchase": false,
      "requiresProviderKey": false,
      "trialUsage": {
        "usageDay": "2026-01-02",
        "dailyRequests": 3,
        "dailyTokens": 1200,
        "dailySpendMicroUsd": 1250000,
        "dailySpendLimitMicroUsd": 5000000,
        "dailyLimitReached": false,
        "resetsAt": "2026-01-03T00:00:00.000Z",
        "totalRequests": 8,
        "totalTokens": 4200,
        "totalSpendMicroUsd": 2000000
      }
    }
    """

    func testBillingStatusRequiresCompleteTypedResponse() throws {
        let decoded = try JSONDecoder().decode(BillingStatus.self, from: Data(validStatus.utf8))
        XCTAssertEqual(decoded.billingStatus, .trialing)
        XCTAssertTrue(decoded.canPurchase)
        XCTAssertTrue(decoded.isTrialing)
        XCTAssertEqual(decoded.trialUsage.dailySpendDollars, 1.25)
        XCTAssertEqual(decoded.trialUsage.dailyLimitDollars, 5)
        XCTAssertEqual(decoded.trialUsage.dailyUsageFraction, 0.25)
        XCTAssertEqual(decoded.trialUsage.totalSpendDollars, 2)
        XCTAssertEqual(decoded.trialUsage.dailyRequests, 3)
        XCTAssertEqual(decoded.trialUsage.totalRequests, 8)
        XCTAssertFalse(decoded.trialUsage.dailyLimitReached)
        XCTAssertNotNil(decoded.trialUsage.resetDate)

        let missingField = validStatus.replacingOccurrences(
            of: "      \"requiresPurchase\": false,\n",
            with: ""
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(BillingStatus.self, from: Data(missingField.utf8))
        )

        let unknownState = validStatus.replacingOccurrences(of: #""trialing""#, with: #""unknown""#)
        XCTAssertThrowsError(
            try JSONDecoder().decode(BillingStatus.self, from: Data(unknownState.utf8))
        )

        let invalidUsage = validStatus.replacingOccurrences(
            of: #""dailySpendMicroUsd": 1250000"#,
            with: #""dailySpendMicroUsd": -1"#
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(BillingStatus.self, from: Data(invalidUsage.utf8))
        )
    }

    func testCheckoutResponseRequiresExplicitReuseAndHTTPSURL() throws {
        let valid = Data(#"{"checkout_url":"https://checkout.example/session","reused":false}"#.utf8)
        XCTAssertEqual(
            try JSONDecoder().decode(CheckoutResponse.self, from: valid).checkoutURL.host,
            "checkout.example"
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                CheckoutResponse.self,
                from: Data(#"{"checkout_url":"http://checkout.example/session","reused":false}"#.utf8)
            )
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                CheckoutResponse.self,
                from: Data(#"{"checkout_url":"https://checkout.example/session"}"#.utf8)
            )
        )
    }

    func testCheckoutReducerHasExplicitBoundedFlowStates() {
        XCTAssertEqual(reduceCheckout(.idle, action: .start), .creating)
        XCTAssertEqual(reduceCheckout(.creating, action: .opened), .pending)
        XCTAssertEqual(reduceCheckout(.pending, action: .timedOut), .timeout)
        XCTAssertEqual(reduceCheckout(.pending, action: .purchased), .success)
        XCTAssertEqual(reduceCheckout(.creating, action: .failed("open failed")), .error("open failed"))
        XCTAssertEqual(reduceCheckout(.success, action: .reset), .idle)
        XCTAssertEqual(reduceCheckout(.pending, action: .start), .pending)
    }
}
