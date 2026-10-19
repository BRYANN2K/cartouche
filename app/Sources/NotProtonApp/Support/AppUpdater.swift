import Sparkle

@MainActor
final class AppUpdater {

    private let controller: SPUStandardUpdaterController
    // The controller keeps its delegate weakly
    private let channels = UpdateChannelDelegate()

    init() {
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
    }

    func check() {
        #if !DEBUG
        controller.checkForUpdates(nil)
        #endif
    }
}
