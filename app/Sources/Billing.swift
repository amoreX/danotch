import Foundation

enum BillingAccountState: String, Codable, Equatable {
    case trialing
    case paid
    case expired
    case revoked
}

struct BillingStatus: Decodable, Equatable {
    let userId: String
    let billingStatus: BillingAccountState
    let trialStartedAt: String
    let trialEndsAt: String
    let trialDaysRemaining: Int
    let lifetimePurchasedAt: String?
    let hasActiveProvider: Bool
    let activeProvider: String?
    let canUseServerKey: Bool
    let requiresPurchase: Bool
    let requiresProviderKey: Bool

    var isPaid: Bool { billingStatus == .paid }
    var isTrialing: Bool { billingStatus == .trialing && trialEndDate > Date() }
    var canPurchase: Bool { !isPaid }
    var trialEndDate: Date {
        guard let date = Self.parseServerDate(trialEndsAt) else {
            preconditionFailure("BillingStatus was initialized with an invalid trialEndsAt")
        }
        return date
    }

    private enum CodingKeys: String, CodingKey {
        case userId
        case billingStatus
        case trialStartedAt
        case trialEndsAt
        case trialDaysRemaining
        case lifetimePurchasedAt
        case hasActiveProvider
        case activeProvider
        case canUseServerKey
        case requiresPurchase
        case requiresProviderKey
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        userId = try values.decode(String.self, forKey: .userId)
        billingStatus = try values.decode(BillingAccountState.self, forKey: .billingStatus)
        trialStartedAt = try values.decode(String.self, forKey: .trialStartedAt)
        trialEndsAt = try values.decode(String.self, forKey: .trialEndsAt)
        trialDaysRemaining = try values.decode(Int.self, forKey: .trialDaysRemaining)
        lifetimePurchasedAt = try values.decode(String?.self, forKey: .lifetimePurchasedAt)
        hasActiveProvider = try values.decode(Bool.self, forKey: .hasActiveProvider)
        activeProvider = try values.decode(String?.self, forKey: .activeProvider)
        canUseServerKey = try values.decode(Bool.self, forKey: .canUseServerKey)
        requiresPurchase = try values.decode(Bool.self, forKey: .requiresPurchase)
        requiresProviderKey = try values.decode(Bool.self, forKey: .requiresProviderKey)

        guard !userId.isEmpty,
              trialDaysRemaining >= 0,
              Self.parseServerDate(trialStartedAt) != nil,
              Self.parseServerDate(trialEndsAt) != nil,
              lifetimePurchasedAt.map({ Self.parseServerDate($0) != nil }) ?? true else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: values.codingPath, debugDescription: "Invalid billing status values")
            )
        }
    }

    static func parseServerDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

struct CheckoutResponse: Decodable, Equatable {
    let checkoutURL: URL
    let reused: Bool

    private enum CodingKeys: String, CodingKey {
        case checkoutURL = "checkout_url"
        case reused
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let rawURL = try values.decode(String.self, forKey: .checkoutURL)
        reused = try values.decode(Bool.self, forKey: .reused)
        guard let url = URL(string: rawURL),
              url.scheme == "https",
              url.host != nil else {
            throw DecodingError.dataCorruptedError(
                forKey: .checkoutURL,
                in: values,
                debugDescription: "Checkout URL must be absolute HTTPS"
            )
        }
        checkoutURL = url
    }
}

enum CheckoutState: Equatable {
    case idle
    case creating
    case pending
    case success
    case timeout
    case error(String)

    var isBusy: Bool {
        self == .creating || self == .pending
    }
}

enum CheckoutAction: Equatable {
    case start
    case opened
    case purchased
    case timedOut
    case failed(String)
    case reset
}

func reduceCheckout(_ state: CheckoutState, action: CheckoutAction) -> CheckoutState {
    switch action {
    case .start:
        return state.isBusy ? state : .creating
    case .opened:
        return state == .creating ? .pending : state
    case .purchased:
        return .success
    case .timedOut:
        return state == .pending ? .timeout : state
    case .failed(let message):
        return .error(message)
    case .reset:
        return .idle
    }
}
