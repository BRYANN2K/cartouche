import Foundation
import Sparkle

@MainActor
final class AppUpdater {

    private var controller: SPUStandardUpdaterController?
    // The controller keeps its delegate weakly
    private let channels = UpdateChannelDelegate()
    // Settings > General's daily switch; tests drive it
    private let dailyChecks: () -> Bool
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, dailyChecks: @escaping () -> Bool = { DailyChecks.enabled() }) {
        self.defaults = defaults
        self.dailyChecks = dailyChecks
    }

    // Built and started from the bootstrap, after the move-to-Applications check
    func start() {
        guard controller == nil else { return }
        #if DEBUG
        let scheduling = false
        #else
        let scheduling = true
        #endif
        controller = SPUStandardUpdaterController(
            startingUpdater: scheduling,
            updaterDelegate: channels,
            userDriverDelegate: nil
        )
        applyDailyChecks()
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyDailyChecks() }
        }
    }

    // The daily switch pauses Sparkle's automatic check; Check for Updates is unaffected.
    // Set only on change so writing the default does not re-fire the observer
    func applyDailyChecks() {
        guard let controller else { return }
        let wanted = dailyChecks()
        if controller.updater.automaticallyChecksForUpdates != wanted {
            controller.updater.automaticallyChecksForUpdates = wanted
        }
    }

    // What Sparkle's automatic check is set to, for tests
    var automaticallyChecks: Bool { controller?.updater.automaticallyChecksForUpdates ?? false }

    func check() {
        #if !DEBUG
        controller?.checkForUpdates(nil)
        #endif
    }
}
