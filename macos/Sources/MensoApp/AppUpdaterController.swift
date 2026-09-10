import Foundation
import Sparkle

/// Owns Sparkle's standard UI for the lifetime of this LSUIElement app.
/// Development bundles and incorrectly packaged releases stay update-disabled
/// instead of starting Sparkle with placeholder or malformed trust material.
@MainActor
final class AppUpdaterController {
    private let standardController: SPUStandardUpdaterController?

    let unavailableReason: String?

    init(bundle: Bundle = .main) {
        if let reason = Self.configurationError(in: bundle) {
            standardController = nil
            unavailableReason = reason
        } else {
            standardController = SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: nil,
                userDriverDelegate: nil
            )
            unavailableReason = nil
        }
    }

    var canCheckForUpdates: Bool {
        standardController?.updater.canCheckForUpdates ?? false
    }

    func checkForUpdates() {
        standardController?.updater.checkForUpdates()
    }

    private static func configurationError(in bundle: Bundle) -> String? {
        guard let feedValue = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              !feedValue.hasPrefix("__"),
              let components = URLComponents(string: feedValue),
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil
        else {
            return "A signed HTTPS update feed is not configured in this build."
        }

        guard let publicKey = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              !publicKey.hasPrefix("__"),
              Data(base64Encoded: publicKey)?.count == 32
        else {
            return "A valid Sparkle Ed25519 public key is not configured in this build."
        }

        guard bundle.object(forInfoDictionaryKey: "SURequireSignedFeed") as? Bool == true,
              bundle.object(forInfoDictionaryKey: "SUVerifyUpdateBeforeExtraction") as? Bool == true,
              (bundle.object(forInfoDictionaryKey: "SUSignedFeedFailureExpirationInterval") as? NSNumber)?.intValue == 0
        else {
            return "Strict signed-feed verification is not enabled in this build."
        }

        return nil
    }
}
