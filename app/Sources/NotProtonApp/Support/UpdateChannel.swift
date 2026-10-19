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
}
