import Foundation
import Sparkle

// Betas are appcast items tagged <sparkle:channel>beta</sparkle:channel>. Sparkle
// offers them only to copies that allow the channel; untagged items reach everyone.
enum UpdateChannel {
    static let betaDefaultsKey = "receiveBetaUpdates"
    static let beta = "beta"

    static func allowed(betaOptIn: Bool) -> Set<String> {
        betaOptIn ? [beta] : []
    }
}

@MainActor
final class UpdateChannelDelegate: NSObject, SPUUpdaterDelegate {

    private let betaOptIn: () -> Bool

    init(betaOptIn: @escaping () -> Bool = { UserDefaults.standard.bool(forKey: UpdateChannel.betaDefaultsKey) }) {
        self.betaOptIn = betaOptIn
    }

    // Read at each check, so the Settings toggle applies to the next one
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        UpdateChannel.allowed(betaOptIn: betaOptIn())
    }

    // QA mode (qa/README.md): the appcast is served by the local mock server.
    // nil outside QA mode leaves Info.plist's SUFeedURL.
    func feedURLString(for updater: SPUUpdater) -> String? {
        guard QAEnvironment.isActive,
              let appcast = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
        else { return nil }
        return QAEnvironment.url(appcast)?.absoluteString
    }
}
