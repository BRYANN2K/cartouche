import AppKit
import Foundation
import InstallerKit
import RetroArchKit
import SwiftUI
import Testing

@testable import NotProtonApp

// The problems the library used to keep to itself: one banner for the library, store and
// console messages, a failed store job that stays in Activity, and a Windows game that quit
// at once or crashed. No test posts a real notification or opens a real log.
@MainActor
@Suite("Problems surface", .serialized)
struct ProblemSurfaceTests {

    private struct Scene {
        let work: URL
        let installs: URL
        let folder: GameFolder
        let game: Game
        let model: LibraryModel
    }

    private func scene(_ label: String, name: String = "Sample Game") throws -> Scene {
        let work = try scratchDirectory(label)
        let installs = work.appending(path: "installs")
        let gameDir = work.appending(path: "games/\(name)")
        let folder = GameFolder(root: installs.appending(path: GameFolder.slug(name)))
        let fm = FileManager.default
        try fm.createDirectory(at: gameDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: folder.prefix, withIntermediateDirectories: true)
        try Data("exe".utf8).write(to: gameDir.appending(path: "game.exe"))
        let record = InstalledGame(
            id: folder.root.lastPathComponent, name: name, appID: nil, gogID: nil,
            runnerID: "r", graphics: GraphicsBackend.wined3d.rawValue, wineVersion: nil, wineRunnerKind: nil,
            prefix: folder.prefix.path(percentEncoded: false),
            exe: gameDir.appending(path: "game.exe").path(percentEncoded: false),
            installedAt: Date(), installerFolder: gameDir.path(percentEncoded: false),
            redistributables: [], gameFolder: gameDir.path(percentEncoded: false))
        try InstalledGames.save(record, in: folder)
        let fixture = try SteamFixture("\(label)-steam")
        let model = libraryModel(fixture, defaults: ScratchDefaults())
        model.installsFolder = installs
        model.showInstalledGames(InstalledGames.all(in: installs))
        return Scene(work: work, installs: installs, folder: folder,
                     game: try #require(model.game("installer:\(folder.root.lastPathComponent)")), model: model)
    }

    // A launcher that exports its wineserver, so the watch has a session to wait out.
    private func launcher(in s: Scene) throws {
        let server = s.work.appending(path: "runner/bin/wineserver")
        let fm = FileManager.default
        try fm.createDirectory(at: server.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: server)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: server.path(percentEncoded: false))
        try Data("""
            #!/bin/sh
            export WINEPREFIX='\(s.folder.prefix.path(percentEncoded: false))'
            export WINESERVER='\(server.path(percentEncoded: false))'
            exec /bin/true
            """.utf8).write(to: s.folder.launcher)
    }

    private func center(_ s: Scene, notifier: RecordingNotifier = RecordingNotifier(), active: Bool = false) -> InstallCenter {
        let c = InstallCenter(engine: InstallEngine(installs: s.installs, runners: s.work.appending(path: "runners"),
                                                    registry: { RunnerRegistry() }),
                              notifier: notifier)
        c.isAppActive = { active }
        c.openLog = { _ in }
        c.waitServer = { _, _, _ in false }
        c.killServer = { _, _ in }
        c.prefixUse = { _ in .free }
        c.hasWindow = { _ in false }
        return c
    }

    private func launch(_ c: InstallCenter, _ s: Scene, _ script: String) throws -> InstallRun {
        let run = InstallRun(InstallLaunch(executable: "/bin/sh", arguments: ["-c", script], environment: [:]))
        try run.start()
        c.watchSession(run, for: s.game, in: s.installs)
        return run
    }

    // MARK: Game exits

    @Test("An exit is unexpected only when nothing of the game is left and nobody stopped it")
    func exitReasons() {
        #expect(GameExit.reason(status: 0, stopped: false, ranFor: 3, crashed: false, outlived: false) == .quick)
        #expect(GameExit.reason(status: 0, stopped: false, ranFor: 600, crashed: false, outlived: false) == nil)
        #expect(GameExit.reason(status: 1, stopped: false, ranFor: 3, crashed: false, outlived: false) == .exitCode(1))
        #expect(GameExit.reason(status: 1, stopped: false, ranFor: 600, crashed: false, outlived: false) == nil)
        #expect(GameExit.reason(status: 0, stopped: false, ranFor: 600, crashed: true, outlived: false) == .crashed)
        #expect(GameExit.reason(status: 5, stopped: true, ranFor: 2, crashed: true, outlived: false) == nil)
        // A stub launcher whose game plays on in its window
        #expect(GameExit.reason(status: 0, stopped: false, ranFor: 1, crashed: false, outlived: true) == nil)
        #expect(GameExit.backtrace("fixme:d3d\nall good\n") == nil)
        #expect(GameExit.backtrace("noise\nwine: Unhandled page fault\nBacktrace:\n=>0 0x1234") == "wine: Unhandled page fault\nBacktrace:\n=>0 0x1234")
    }

    @Test("Copy Summary names the game, its runner and how it ended, with the backtrace and the home folder as ~")
    func summaryText() throws {
        let s = try scene("exit-summary")
        defer { try? FileManager.default.removeItem(at: s.work) }
        let crash = s.folder.root.appending(path: "crash-1.log")
        try Data("fixme:dxgi\nUnhandled exception: page fault on read access to 0x00000000 in 64-bit code\nBacktrace:\n=>0 game.exe+0x10\n".utf8)
            .write(to: crash)
        var home = s.work.path(percentEncoded: false)
        if home.hasSuffix("/") { home.removeLast() }
        let text = GameExit.summary(name: "Sample Game", reason: .crashed, status: 5, ranFor: 2.4, folder: s.folder,
                                    crashLog: crash, home: home)
        #expect(text.contains("Game: Sample Game"))
        #expect(text.contains("Runner: r"))
        #expect(text.contains("exit status 5, after 2 s"))
        #expect(text.contains("Unhandled exception: page fault"))
        #expect(text.contains("=>0 game.exe+0x10"))
        #expect(!text.contains("fixme:dxgi"))
        #expect(!text.contains(home))
        #expect(text.contains("Log: ~/"))

        // No crash: the tail of the game's own log
        try Data("err:module:import_dll Library d3d11.dll not found\n".utf8).write(to: s.folder.gameLog)
        let quick = GameExit.summary(name: "Sample Game", reason: .quick, status: 0, ranFor: 1, folder: s.folder,
                                     crashLog: nil, home: home)
        #expect(quick.contains("closed right after it started"))
        #expect(quick.contains("d3d11.dll not found"))
    }

    @Test("A game that closes at once reads '<Game> quit unexpectedly' with Show Log and Copy Summary, and notifies in the background")
    func quickExitNotice() async throws {
        let s = try scene("exit-quick")
        defer { try? FileManager.default.removeItem(at: s.work) }
        try launcher(in: s)
        let notifier = RecordingNotifier()
        let c = center(s, notifier: notifier)
        let opened = Box<[URL]>([])
        c.openLog = { opened.value.append($0) }

        _ = try launch(c, s, "exit 0")
        #expect(await waitFor { c.exitNotice != nil })
        let notice = try #require(c.exitNotice)
        #expect(notice.reason == .quick)
        #expect(notice.title == "Sample Game quit unexpectedly")
        #expect(notice.detail == "It closed a few seconds after it started.")
        #expect(notice.log == s.folder.gameLog)
        #expect(notifier.posted == ["quit Sample Game"])

        let shown = try #require(ProblemBoard.pick(exit: c.exitNotice, library: "Older problem", stores: nil, consoles: nil))
        #expect(shown.title == "Sample Game quit unexpectedly")
        #expect(shown.actions == [.showLog, .copySummary])
        let texts = try await renderedTexts(ProblemBanner(model: s.model, installs: c).frame(width: 760).padding(8),
                                            size: CGSize(width: 780, height: 110), named: "problem-banner-exit")
        #expect(seen(texts, "Sample Game quit unexpectedly"), "\(texts)")
        #expect(seen(texts, "Show Log"), "\(texts)")
        #expect(seen(texts, "Copy Summary"), "\(texts)")

        c.showExitLog(gameID: s.game.id)
        #expect(opened.value == [s.folder.gameLog])
        // A stale dismiss leaves the notice; its own clears it
        c.dismissExit(UUID())
        #expect(c.exitNotice == notice)
        ProblemBoard.clear(shown, library: s.model, stores: nil, consoles: nil, installs: c)
        #expect(c.exitNotice == nil)
    }

    @Test("An error exit names its code; with Cartouche in front no notification goes out")
    func errorExitNotice() async throws {
        let s = try scene("exit-code")
        defer { try? FileManager.default.removeItem(at: s.work) }
        try launcher(in: s)
        let notifier = RecordingNotifier()
        let c = center(s, notifier: notifier, active: true)
        _ = try launch(c, s, "exit 3")
        #expect(await waitFor { c.exitNotice != nil })
        #expect(c.exitNotice?.reason == .exitCode(3))
        #expect(c.exitNotice?.detail == "It stopped with exit code 3.")
        #expect(notifier.posted.isEmpty)
    }

    @Test("A crash shows at once with the kept backtrace as its log and in Copy Summary")
    func crashNotice() async throws {
        let s = try scene("exit-crash")
        defer { try? FileManager.default.removeItem(at: s.work) }
        try launcher(in: s)
        let c = center(s)
        // The session is never drained while the notice is checked: the crash does not wait for it
        let release = Box(false)
        c.waitServer = { _, _, _ in
            while !release.value { try? await Task.sleep(for: .milliseconds(20)) }
            return false
        }
        defer { release.value = true }
        try Data("Unhandled exception: page fault on read access to 0x00000000 in 64-bit code\nBacktrace:\n=>0 game.exe+0x10\n".utf8)
            .write(to: s.folder.gameLog)
        _ = try launch(c, s, "exit 1")
        #expect(await waitFor { c.exitNotice != nil })
        let notice = try #require(c.exitNotice)
        #expect(notice.reason == .crashed)
        #expect(notice.log == CrashLog.latest(in: s.folder.root))
        #expect(notice.summary.contains("Backtrace:"))
        #expect(notice.detail == "It crashed. Its log keeps the backtrace.")
    }

    @Test("Stop, End Wine Session, a game window that stays and a client in the session are not unexpected")
    func expectedExits() async throws {
        let s = try scene("exit-expected")
        defer { try? FileManager.default.removeItem(at: s.work) }
        try launcher(in: s)
        let notifier = RecordingNotifier()
        let c = center(s, notifier: notifier)

        // Stop
        _ = try launch(c, s, "sleep 30")
        #expect(c.isPlaying(s.game))
        c.stopGame(s.game, in: s.installs)
        #expect(await waitFor { !c.playingGames.contains(s.game.id) })
        try? await Task.sleep(for: .seconds(1))
        #expect(c.exitNotice == nil)

        // End Wine Session while the launcher still runs
        let ended = try launch(c, s, "sleep 30")
        c.endSession(for: s.game, in: s.installs)
        // wineserver -k is a stub here, so the launcher is ended the way -k would end it
        kill(ended.pid, SIGTERM)
        #expect(await waitFor { !c.playingGames.contains(s.game.id) })
        try? await Task.sleep(for: .seconds(1))
        #expect(c.exitNotice == nil)

        // The launcher was a stub: the game's window stays, then closes
        let window = Box(true)
        let kills = Box(0)
        c.hasWindow = { _ in window.value }
        c.killServer = { _, _ in kills.value += 1 }
        c.waitServer = { _, _, _ in
            try? await Task.sleep(for: .milliseconds(50))
            return true
        }
        c.prefixUse = { _ in kills.value > 0 ? .free : .running(.game) }
        _ = try launch(c, s, "exit 0")
        try? await Task.sleep(for: .milliseconds(400))
        window.value = false
        #expect(await waitFor { kills.value == 1 })
        try? await Task.sleep(for: .seconds(1))
        #expect(c.exitNotice == nil)

        // A store client keeps the session up
        c.prefixUse = { _ in .running(.store("Steam")) }
        _ = try launch(c, s, "exit 0")
        #expect(await waitFor { c.busyClients[s.game.id] == .store("Steam") })
        try? await Task.sleep(for: .milliseconds(500))
        #expect(c.exitNotice == nil)
        #expect(notifier.posted.isEmpty)
    }

    @Test("The quit notification reads '<Game> quit unexpectedly' and its Show Log reaches the game's log")
    func quitNotification() throws {
        let poster = RecordingPoster()
        let router = NotificationRouter()
        let notifier = UserInstallNotifier(poster: poster, router: router)
        var shown: [String] = []
        notifier.onShowLog = { shown.append($0) }
        notifier.quitUnexpectedly(name: "Sample Game", gameID: "installer:sample-game")
        let spec = try #require(poster.posted.first)
        #expect(spec.title == "Sample Game quit unexpectedly")
        #expect(spec.body == "Open Cartouche to see its log or copy a summary.")
        #expect(spec.actionTitle == "Show Log")
        #expect(spec.category == UserInstallNotifier.quitCategory)
        router.respond(category: spec.category, action: "com.apple.UNNotificationDefaultActionIdentifier", userInfo: spec.userInfo)
        #expect(shown.isEmpty)
        router.respond(category: spec.category, action: spec.action, userInfo: spec.userInfo)
        #expect(shown == ["installer:sample-game"])
    }

    // MARK: The banner

    @Test("The banner shows one problem at a time and offers Settings… for a missing runner")
    func pickOrder() {
        let runner = "Set up a runner in Settings > Compatibility to play Sample Game."
        #expect(ProblemBoard.needsRunner(runner))
        #expect(!ProblemBoard.needsRunner("Cartouche couldn’t start Sample Game: denied"))
        #expect(!ProblemBoard.needsRunner("Set up a runner in Settings > Compatibility to play ."))

        let library = ProblemBoard.pick(exit: nil, library: runner, stores: "Store trouble", consoles: "Console trouble")
        #expect(library == ShownProblem(source: .library, title: runner, actions: [.openSettings(.compatibility)]))
        let stores = ProblemBoard.pick(exit: nil, library: nil, stores: "Store trouble", consoles: "Console trouble")
        #expect(stores == ShownProblem(source: .stores, title: "Store trouble"))
        // A failed download already in Activity is not shown twice
        let consoles = ProblemBoard.pick(exit: nil, library: nil, stores: "Store trouble", storeFailures: ["Store trouble"],
                                         consoles: "Dolphin is not installed",
                                         consoleNeedsSettings: { ProblemBoard.consoleNeedsSettings($0, consoles: nil) })
        #expect(consoles == ShownProblem(source: .consoles, title: "Dolphin is not installed", actions: [.openSettings(.consoles)]))
        #expect(ProblemBoard.pick(exit: nil, library: nil, stores: nil, consoles: nil) == nil)
    }

    @Test("Dismiss clears only the problem it showed: a newer one set meanwhile stays")
    func dismissKeepsNewer() async throws {
        let s = try scene("problem-dismiss")
        defer { try? FileManager.default.removeItem(at: s.work) }
        let c = center(s)
        s.model.problem = "Cartouche couldn’t rename Sample Game: denied"
        let shown = try #require(ProblemBoard.pick(exit: nil, library: s.model.problem, stores: nil, consoles: nil))
        #expect(shown.actions.isEmpty)
        let texts = try await renderedTexts(ProblemBanner(model: s.model, installs: c).frame(width: 760).padding(8),
                                            size: CGSize(width: 780, height: 90), named: "problem-banner-library")
        #expect(seen(texts, "couldn’t rename Sample Game") || seen(texts, "couldn't rename Sample Game"), "\(texts)")

        s.model.problem = "Cartouche couldn’t remove Sample Game: busy"
        ProblemBoard.clear(shown, library: s.model, stores: nil, consoles: nil, installs: c)
        #expect(s.model.problem == "Cartouche couldn’t remove Sample Game: busy")
        let newer = try #require(ProblemBoard.pick(exit: nil, library: s.model.problem, stores: nil, consoles: nil))
        ProblemBoard.clear(newer, library: s.model, stores: nil, consoles: nil, installs: c)
        #expect(s.model.problem == nil)
    }

    @Test("A missing BIOS from Play shows in the banner with Settings… for Consoles")
    func consoleBIOS() async throws {
        let scene = try await ConsoleScene("problem-bios")
        defer { scene.remove() }
        _ = scene.useFakeRunner(picture: try ConsolePanelTests.screen("PS"))
        let game = try await scene.addGame(console: "ps1", name: "Test Disc", ext: "cue")
        await scene.center.play(game.id, reduceMotion: true)
        let problem = try #require(scene.center.problem)
        #expect(ProblemBoard.consoleNeedsSettings(problem, consoles: scene.center))
        #expect(!ProblemBoard.consoleNeedsSettings("Super Nintendo is playing. Quit the game first.", consoles: scene.center))
        let shown = ProblemBoard.pick(exit: nil, library: nil, stores: nil, consoles: problem,
                                      consoleNeedsSettings: { ProblemBoard.consoleNeedsSettings($0, consoles: scene.center) })
        #expect(shown?.actions == [.openSettings(.consoles)])
        ProblemBoard.clear(try #require(shown), library: scene.library, stores: nil, consoles: scene.center, installs: InstallCenter(notifier: RecordingNotifier()))
        #expect(scene.center.problem == nil)
    }

    // MARK: Store jobs

    @Test("A failed store download stays in Activity with its reason; Dismiss clears it, Try Again runs it again")
    func failedStoreJob() async throws {
        let scene = try await StoreScene("failed-job")
        defer { scene.remove() }
        await scene.signIn(.epic, code: "epic-good-code")
        let activity = ActivityCenter(installs: InstallCenter(notifier: RecordingNotifier()), control: RecordingControl(),
                                      notifier: RecordingActivityNotifier())
        activity.storeSource = { [scene] in scene.center.activity }
        activity.storeFailures = { [scene] in scene.center.failures }
        activity.retryStore = { [scene] in scene.center.retry($0) }
        activity.dismissStore = { [scene] in scene.center.dismiss($0) }
        let game = try #require(scene.model.game("epic:Fennec"))

        scene.flag("fail-install")
        scene.center.install(game)
        #expect(await scene.waitForJobs())
        let failure = try #require(scene.center.failures.first)
        #expect(failure.gameID == "epic:Fennec")
        #expect(failure.label == "Download failed")
        #expect(failure.reason == "Not enough available disk space!")
        #expect(failure.canRetry)
        #expect(activity.slot == .storeFailed(failure))
        #expect(activity.menuSections.map(\.kind) == [.store])
        #expect(activity.menuSections.first?.lines.last == ActivityMenuSection.Line(title: failure.title, detail: "Download failed"))
        // The banner leaves it to Activity
        #expect(scene.center.problem == failure.reason)
        #expect(ProblemBoard.pick(exit: nil, library: nil, stores: scene.center.problem,
                                  storeFailures: scene.center.failures.map(\.reason), consoles: nil) == nil)
        for dark in [false, true] {
            await windowSnapshot(LibrarySidebar(model: scene.model).activitySlot(activity, library: scene.model),
                                 named: "store-activity-failed", size: CGSize(width: 260, height: 600), dark: dark)
        }

        activity.dismissStore(failure)
        #expect(scene.center.failures.isEmpty)
        #expect(scene.center.problem == nil)
        #expect(activity.slot == nil)

        scene.center.install(game)
        #expect(await scene.waitForJobs())
        let again = try #require(scene.center.failures.first)
        scene.flag("fail-install", false)
        activity.retryStore(again)
        #expect(await scene.waitUntil { scene.center.record("epic:Fennec") != nil })
        #expect(await scene.waitForJobs())
        #expect(scene.center.failures.isEmpty)
        #expect(activity.slot == nil)
    }

    @Test("A store job the user stopped leaves Activity instead of reading as failed")
    func stoppedStoreJob() async throws {
        let scene = try await StoreScene("stopped-job")
        defer { scene.remove() }
        await scene.signIn(.epic, code: "epic-good-code")
        scene.flag("slow")
        scene.center.install(try #require(scene.model.game("epic:Fennec")))
        #expect(await scene.waitUntil { (scene.center.activity?.fraction ?? 0) > 0 })
        scene.center.stop(try #require(scene.center.activity))
        #expect(await scene.waitForJobs())
        #expect(scene.center.failures.isEmpty)
        #expect(scene.center.jobs.isEmpty)
    }

    @Test("The failed card shows its label, the game, the reason, Try Again and Dismiss; an import only Dismiss")
    func failedCardTexts() async throws {
        let failure = StoreFailure(id: UUID(), gameID: "epic:Fennec", title: "Sample Free Game", kind: .update,
                                   reason: "Not enough available disk space!")
        let texts = try await renderedTexts(
            StoreFailedCard(failure: failure, retry: {}, dismiss: {}, show: {}).frame(width: 220).padding(12),
            size: CGSize(width: 240, height: 140), named: "store-failed-card")
        for wanted in ["Update failed", "Sample Free Game", "disk space", "Try Again", "Dismiss"] {
            #expect(seen(texts, wanted), "\(wanted): \(texts)")
        }
        let imported = StoreFailure(id: UUID(), gameID: "epic:import:Folder", title: "Folder", kind: .importing, reason: "No game")
        #expect(!imported.canRetry)
        #expect(imported.label == "Import failed")
        #expect(ActivitySlot.pick(playing: nil, install: nil, store: epicDownload, storeFailed: imported, downloads: [])
                == .store(epicDownload))
        #expect(ActivitySlot.pick(playing: nil, install: nil, store: nil, storeFailed: imported, downloads: [])
                == .storeFailed(imported))
    }
}
