import Sparkle

@MainActor
final class AppUpdater {

    private let controller: SPUStandardUpdaterController
    // The controller keeps its delegate weakly
    private let channels = UpdateChannelDelegate()
    // Settings > General's daily switch; tests drive it
    private let dailyChecks: () -> Bool

    init(dailyChecks: @escaping () -> Bool = { DailyChecks.enabled() }) {
        self.dailyChecks = dailyChecks
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
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.applyDailyChecks() }
        }
    }

    // The daily switch pauses Sparkle's automatic check; Check for Updates is unaffected.
    // Set only on change so writing the default does not re-fire the observer
    func applyDailyChecks() {
        let wanted = dailyChecks()
        if controller.updater.automaticallyChecksForUpdates != wanted {
            controller.updater.automaticallyChecksForUpdates = wanted
        }
    }

    // What Sparkle's automatic check is set to, for tests
    var automaticallyChecks: Bool { controller.updater.automaticallyChecksForUpdates }

    func check() {
        #if !DEBUG
        controller.checkForUpdates(nil)
        #endif
    }
}
