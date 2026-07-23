import Combine
import Foundation
#if canImport(Sparkle)
import Sparkle
#endif

@MainActor
final class UpdateController: ObservableObject {
    static let shared = UpdateController()

#if canImport(Sparkle)
    let updaterController: SPUStandardUpdaterController
#endif
    @Published private(set) var canCheckForUpdates = false
    let configurationError: String?

    private init(bundle: Bundle = .main) {
        configurationError = Self.configurationError(bundle: bundle)
#if canImport(Sparkle)
        updaterController = SPUStandardUpdaterController(
            startingUpdater: configurationError == nil,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        updaterController.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
#endif
    }

    func checkForUpdates() {
        guard configurationError == nil else { return }
#if canImport(Sparkle)
        updaterController.checkForUpdates(nil)
#endif
    }

    static func configurationError(bundle: Bundle) -> String? {
        guard let feed = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let url = URL(string: feed),
              url.scheme?.lowercased() == "https",
              url.host != nil else {
            return "A secure Sparkle feed URL is not configured."
        }
        guard let publicKey = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              let keyData = Data(base64Encoded: publicKey),
              keyData.count == 32 else {
            return "A valid Sparkle Ed25519 public key is not configured."
        }
        return nil
    }
}
