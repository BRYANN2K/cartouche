import Foundation
import Sparkle

@MainActor
final class AppUpdater {

    private var controller: SPUStandardUpdaterController?
    private let channels = UpdateChannelDelegate()
    private let dailyChecks: () -> Bool
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, dailyChecks: @escaping () -> Bool = { DailyChecks.enabled() }) {
        self.defaults = defaults
        self.dailyChecks = dailyChecks
    }

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

    func applyDailyChecks() {
        guard let controller else { return }
        let wanted = dailyChecks()
        if controller.updater.automaticallyChecksForUpdates != wanted {
            controller.updater.automaticallyChecksForUpdates = wanted
        }
    }

    var automaticallyChecks: Bool { controller?.updater.automaticallyChecksForUpdates ?? false }

    func check() {
        #if !DEBUG
        controller?.checkForUpdates(nil)
        #endif
    }
}
