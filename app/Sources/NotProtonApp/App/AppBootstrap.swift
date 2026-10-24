import SwiftUI

// Runs before any scene exists and before the updater starts: a copy outside Applications offers to move there and relaunch (permissions and updates stay with it)
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { _ = MoveToApplications.check() }
    }
}

extension CartoucheApp {

    // The window's .task re-fires each time the window reopens; the bootstrap runs once
    func start() async {
        guard !started else { await library.load(); return }
        started = true
        updater.start()
        permissions.watchActivation()
        await crashReports.check()
        var route: ScreenRoute?
        if onboarding == nil {
            let model = makeOnboarding()
            onboarding = model
            route = relaunch.restore()
            if let route, route.screen == "onboarding" {
                model.reopen(on: route)
            } else {
                model.presentIfDue()
            }
        }
        NotificationRouter.shared.install()
        AgentNotifier.register()
        steamSetup.onInstalled = { [library] in Task { await library.load() } }
        network.start { [library] offline in library.isOffline = offline }
        await compat.load()
        await performance.refresh()
        await library.load()
        library.watch()
        await consoleCenter.reload()
        await consoleCenter.reattachOrphaned()
        consoleCenter.folderList = gameFolders
        consoleCenter.netplayFlow = PermissionFlow(center: permissions)
        await consoleCenter.startWatching()
        controls.couch.play = { [actions] game in actions.perform(game.installed ? .play : .install, on: game) }
        await controls.start(relaunch: relaunch, library: library)
        if let route, route.screen == "controls" { await controls.reopen(route) }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) {
            [consoleCenter, controls] _ in MainActor.assumeIsolated {
                controls.endForTermination()
                consoleCenter.endForTermination()
            }
        }
        await startActivity()
        await loadRunners()
        startStores()
        await compat.refresh()
        // Only what the user confirmed waits in the queue; nothing new is collected here
        Task { await contributions.drain() }
    }

    private func startStores() {
        stores.afterLaunch = actions.afterLaunch
        let index = TitleIndex()
        stores.matchAppID = { [compat] title in index.appID(title, data: compat.data) }
        let activity = ActivityCenter.shared
        activity.storeSource = { [stores] in stores.activity }
        activity.stopStore = { [stores] in stores.stop($0) }
        Task { await stores.start(refresh: !library.isOffline) }
    }

    private func startActivity() async {
        RevealRenderer.warmUp()
        await permissions.refresh(.notifications)
        let activity = ActivityCenter.shared
        activity.permissionFlow = permissionFlow
        InstallCenter.shared.permissionFlow = permissionFlow
        InstallCenter.shared.onVerificationMismatch = { [verification] job in
            verification.presentMismatch(for: job)
        }
        activity.follow(consoleCenter)
        activity.onDownloadFinished = { [library] _ in Task { await library.load() } }
        activity.onGameEnded = { [performance] in Task { await performance.refresh() } }
        activity.watch()
    }
}
