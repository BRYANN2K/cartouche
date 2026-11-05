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
        runners.didChange = { [weak runners, weak library, status] in
            guard let runners, let library else { return }
            await Self.syncRunnerList(runners: runners, into: library)
            await status.refresh()
        }
        updater.start()
        permissions.watchActivation()
        await crashReports.check()
        Task.detached(priority: .utility) { MetalCacheMigration.run() }
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
            whatsNew.presentIfDue(onboardingDue: model.isDue)
        }
        NotificationRouter.shared.install()
        startResources()
        AgentNotifier.register()
        steamSetup.onInstalled = { [library] in Task { await library.load() } }
        network.start { [library] offline in library.isOffline = offline }
        await compat.load()
        library.antiCheat = { [compat] game in
            guard let appID = game.steamAppID ?? game.compatAppID else { return nil }
            return compat.antiCheat(appID: appID)?.name
        }
        await performance.refresh()
        // Explicit installations reload the import; Steam quitting only refreshes the status.
        status.onUpkeepInstalled = { [library] in await library.load() }
        library.onSteamQuit = { [status] in await status.keepSteamIntegrationCurrent() }
        await library.load()
        library.watch()
        await consoleCenter.reload()
        await consoleCenter.reattachOrphaned()
        consoleCenter.folderList = gameFolders
        consoleCenter.netplayFlow = PermissionFlow(center: permissions)
        // An unavailable game folder must not delay controllers, runners or stores.
        Task { [consoleCenter] in await consoleCenter.startWatching() }
        controls.couch.play = { [actions] game in actions.perform(game.installed ? .play : .install, on: game) }
        await controls.start(relaunch: relaunch, library: library)
        if let route, route.screen == "controls" { await controls.reopen(route) }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) {
            [consoleCenter, controls, resources] _ in MainActor.assumeIsolated {
                resources.resumeAll(why: "Cartouche quit")
                controls.endForTermination()
                consoleCenter.endForTermination()
            }
        }
        await startActivity()
        library.reloadRunners = { [runners, weak library] in
            guard let library else { return }
            await Self.loadRunners(runners: runners, into: library)
        }
        runners.migrateGames = { [weak runners, weak library] old, new in
            guard let runners, let library else { return }
            await Self.syncRunnerList(runners: runners, into: library)
            try await library.moveGames(from: old, to: new)
        }
        await loadRunners()
        startStores()
        await compat.refresh()
        Task { [compat] in await compat.keepFresh() }
        // Only what the user confirmed waits in the queue; nothing new is collected here
        Task { await contributions.drain() }
    }

    // Processes a crashed Cartouche left paused go again before anything else runs.
    private func startResources() {
        resources.start()
        resources.contextFolder = SupportPaths.performance.appending(path: PerformanceIncoming.folderName)
        resources.showWindow = { BackgroundAppsPresenter.shared.show() }
        BackgroundAppsPresenter.shared.showMainWindow = {
            NSApp.activate()
            NSApp.windows.first { $0.identifier?.rawValue.hasPrefix(CartoucheApp.mainWindow) == true }?.makeKeyAndOrderFront(nil)
        }
        resources.notify = { NotificationRouter.shared.post(ResourceAlertText.notification($0)) }
        NotificationRouter.shared.handle(category: ResourceAlertText.category) { [resources] _, _ in
            BackgroundAppsPresenter.shared.show()
            resources.alert = nil
        }
        let overlay = OverlayController.shared
        overlay.resources = resources
        overlay.actions.setResumeApps = { [resources] in resources.resumesAfterGame = $0 }
        // The menu edits the library game's profile, the one the game page shows
        overlay.resolveGame = { [library] app in
            guard var game = OverlayController.gameFromProcess(app) else { return nil }
            let info = GameProcesses.info(of: app.processIdentifier)
            let playing = ActivityCenter.shared.playing.flatMap { if case .steam = $0.target { $0.id } else { nil } }
            guard let match = library.allGames.first(where: { $0.id == game.id }) ?? OverlayGameMatch.match(
                name: game.name, appID: info.flatMap { OverlayGameMatch.steamAppID($0.environment) },
                exe: info?.arguments.first { $0.lowercased().hasSuffix(".exe") }, playingID: playing,
                games: library.allGames, folder: { library.installFolder(of: $0) }) else { return game }
            let legacy = game.id
            game.id = match.id
            game.name = match.name
            let setup = library.resolution(for: match).setup
            let scan = library.folderScan(for: match), profile = library.launchProfile(for: match)
            game.dlss = profile.dlss && AdvancedSupport.options(runner: setup.runner, backend: setup.backend,
                translation: setup.translation, availability: library.backendAvailability).contains(.dlss)
            game.antiCheat = game.antiCheat ?? scan?.antiCheat ?? library.antiCheat(match)
            // A folder not yet scanned counts as protected until it proves clean
            if profile.protected { game.antiCheat = game.antiCheat ?? ot("Anti-cheat") }
            game.libraryLoaded = library.framegenLaunched[match.id] ?? false
            Self.keepLegacyProfile(legacy, for: &game, profiles: library.profiles)
            return game
        }
        overlay.actions.applyLaunch = { [library] game, _ in library.profileSaved(game.id) }
        resources.gameStarted = { overlay.gameStarted() }
        resources.gameEnded = { overlay.gameEnded() }
        resources.isGameRunning = { [relaunch, stores] in
            if ActivityCenter.shared.playing != nil || !InstallCenter.shared.playingGames.isEmpty || !stores.playing.isEmpty {
                return true
            }
            return await relaunch.games.isGameRunning()
        }
    }

    private func startStores() {
        stores.afterLaunch = actions.afterLaunch
        let index = TitleIndex()
        stores.matchAppID = { [compat] title in index.appID(title, data: compat.data) }
        let activity = ActivityCenter.shared
        activity.storeSource = { [stores] in stores.activity }
        activity.stopStore = { [stores] in stores.stop($0) }
        activity.storeFailures = { [stores] in stores.failures }
        activity.retryStore = { [stores] in stores.retry($0) }
        activity.dismissStore = { [stores] in stores.dismiss($0) }
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
        activity.onSteamSnapshot = { SteamInstallCenter.shared.reconcile($0) }
        activity.onGameEnded = { [performance] in Task { await performance.refresh() } }
        InstallCenter.shared.onSessionEnded = { [performance] in Task { await performance.refresh() } }
        activity.watch()
    }

    // The profile the process id carried moves to the library id; a failed copy keeps reading the old one
    static func keepLegacyProfile(_ legacy: String, for game: inout OverlayGame, profiles: OverlayProfileStore,
                                  log: (String) -> Void = AppLog.note) {
        guard profiles.profile(for: game.id) == nil, let old = profiles.profile(for: legacy) else { return }
        do { try profiles.save(old, for: game.id) } catch {
            log("game profile not copied from \(legacy) to \(game.id): \(error.localizedDescription)")
            game.id = legacy
        }
    }
}
