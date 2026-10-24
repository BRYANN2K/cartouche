import Darwin
import Foundation
import Testing

@testable import NotProtonApp

// Wine Tools from the game's own menu and panel, and Stop for a Steam game run through Wine.
// Prefixes are folders in scratch directories; no Wine runs and no real Steam file is read.
@Suite("Game Wine Tools and Steam Stop", .serialized)
@MainActor
struct GameWineToolsTests {

    static let toolTitles = ["Wine Configuration", "Registry Editor", "Winetricks…", "Run Program in Prefix…", "",
                             "Open C: Drive", "Show Log"]

    private func steamModel(_ label: String) async throws -> (LibraryModel, SteamFixture) {
        let fixture = try SteamFixture(label)
        try fixture.writeExport()
        let model = libraryModel(fixture, defaults: ScratchDefaults())
        await model.load()
        model.runners = [GameSetupTests.release]
        return (model, fixture)
    }

    private func activity(running appID: Int? = nil, steam: URL) -> ActivityCenter {
        let center = ActivityCenter(installs: InstallCenter(notifier: RecordingNotifier()),
                                    reader: SteamActivityReader(files: SteamLocalFiles(userData: steam)),
                                    control: RecordingControl(), notifier: RecordingActivityNotifier(),
                                    steamRunning: { false })
        center.apply(SteamActivitySnapshot(runningAppID: appID, names: appID.map { [$0: "Counter-Strike 2"] } ?? [:]))
        return center
    }

    private func tools(_ items: [GameMenuItem]) -> GameMenuItem? {
        items.first { $0.title == "Wine Tools" }
    }

    private static func spawn(_ path: String, _ arguments: [String]) throws -> Process {
        let p = Process()
        p.executableURL = URL(filePath: path)
        p.arguments = arguments
        try p.run()
        return p
    }

    // MARK: Menu

    @Test("An installed Windows game has a Wine Tools submenu after Graphics; a Mac build or a game not installed has none")
    func menu() async throws {
        let (model, fixture) = try await steamModel("wine-tools-menu")
        defer { fixture.remove() }
        let center = activity(steam: fixture.steam)
        let cs2 = try #require(model.game("steam:730"))
        let items = GameMenu.items(for: cs2, in: model, activity: center)
        let submenu = try #require(tools(items))
        #expect(submenu.action == nil)
        #expect(submenu.children.map(\.title) == Self.toolTitles)
        #expect(submenu.children.map(\.action) == [.wineTool(.winecfg), .wineTool(.regedit), .winetricks, .runInPrefix, nil,
                                                    .openDriveC, .showLog])
        #expect(!submenu.children.contains { $0.disabled })
        let graphics = try #require(items.firstIndex { $0.title == "Graphics" })
        #expect(items[graphics + 1].title == "Wine Tools")

        let apex = try #require(model.game("steam:1172470"))
        #expect(tools(GameMenu.items(for: apex, in: model, activity: center)) == nil)
        model.macBuilds = [730]
        #expect(tools(GameMenu.items(for: try #require(model.game("steam:730")), in: model, activity: center)) == nil)
    }

    @Test("A store game without a runner keeps only Open C: Drive and Show Log")
    func withoutWine() {
        #expect(GameMenu.wineToolItems(hasWine: false, busy: false).map(\.title) == ["Open C: Drive", "Show Log"])
        let busy = GameMenu.wineToolItems(hasWine: true, busy: true)
        #expect(busy.filter(\.disabled).map(\.title) == ["Wine Configuration", "Registry Editor", "Winetricks…", "Run Program in Prefix…"])
    }

    // MARK: Steam running state

    @Test("A Steam game Steam runs shows as running: Play is Stop and the tools that change the prefix wait")
    func steamRunning() async throws {
        let (model, fixture) = try await steamModel("wine-tools-running")
        defer { fixture.remove() }
        let center = activity(running: 730, steam: fixture.steam)
        let cs2 = try #require(model.game("steam:730"))
        let items = GameMenu.items(for: cs2, in: model, activity: center)
        #expect(items.first?.action == .stopGame)
        #expect(items.first?.title == "Stop Game")
        #expect(items.first?.shortcut == nil)
        let submenu = try #require(tools(items))
        #expect(submenu.children.filter { !$0.isDivider && $0.disabled }.map(\.title)
                == ["Wine Configuration", "Registry Editor", "Winetricks…", "Run Program in Prefix…"])
        #expect(submenu.children.filter { !$0.isDivider && !$0.disabled }.map(\.title) == ["Open C: Drive", "Show Log"])
        #expect(GamePanelContent.isRunning(cs2, store: false, local: false,
                                           steam: GameMenu.steamRunning(cs2, in: model, activity: center)))

        // Another game Steam runs leaves this one on Play
        let elden = try #require(model.game("steam:1245620"))
        #expect(GameMenu.items(for: elden, in: model, activity: center).first?.action == .play)
        // Native games also expose Stop; they use their own process tracking.
        model.macBuilds = [730]
        #expect(GameMenu.steamRunning(try #require(model.game("steam:730")), in: model, activity: center))
    }

    @Test("Stop on a running Steam game stops its prefix off the main actor, then reads Steam again")
    func steamStop() async throws {
        let (model, fixture) = try await steamModel("wine-tools-stop")
        defer { fixture.remove() }
        let center = activity(running: 730, steam: fixture.steam)
        let asked = Box<[(Int, URL, Bool)]>([])
        var runner = GameActionRunner(model: model, open: { _ in })
        runner.activity = center
        runner.stopSteamGame = { appID, files in
            let onMain = Thread.isMainThread
            DispatchQueue.main.async { asked.value.append((appID, files.userData, onMain)) }
            return .stopped(3)
        }
        let cs2 = try #require(model.game("steam:730"))
        runner.perform(.stopGame, on: cs2)
        #expect(await waitFor { center.steamGame == nil && !asked.value.isEmpty })
        #expect(asked.value.map(\.0) == [730])
        #expect(asked.value.first?.1 == fixture.steam)
        #expect(asked.value.first?.2 == false)
        #expect(model.problem == nil)

        runner.stopSteamGame = { _, _ in .noPrefix }
        runner.perform(.stopGame, on: cs2)
        #expect(await waitFor { model.problem != nil })
        #expect(model.problem?.contains("Windows prefix") == true)
    }

    @Test("While the Steam game runs, the menu's prefix tools do nothing even when called directly")
    func toolsWaitWhileRunning() async throws {
        let (model, fixture) = try await steamModel("wine-tools-guard")
        defer { fixture.remove() }
        let launched = Box(0)
        var runner = GameActionRunner(model: model, open: { _ in })
        runner.activity = activity(running: 730, steam: fixture.steam)
        runner.launchTool = { _, _ in launched.value += 1 }
        runner.chooseProgram = { _ in Issue.record("no program picker while running"); return nil }
        runner.winetricksPrompt = { _ in Issue.record("no Winetricks prompt while running"); return nil }
        let cs2 = try #require(model.game("steam:730"))
        for action in [GameAction.wineTool(.winecfg), .wineTool(.regedit), .runInPrefix, .winetricks] {
            runner.perform(action, on: cs2)
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(launched.value == 0)
        #expect(model.problem == nil)
    }

    @Test("Open C: Drive opens the compatdata prefix of the library holding the game; before a first run it says so")
    func steamDriveC() async throws {
        let (model, fixture) = try await steamModel("wine-tools-drive")
        defer { fixture.remove() }
        let opened = Box<[URL]>([])
        var runner = GameActionRunner(model: model, open: { opened.value.append($0) })
        runner.activity = activity(steam: fixture.steam)
        let cs2 = try #require(model.game("steam:730"))

        runner.perform(.openDriveC, on: cs2)
        #expect(await waitFor { model.problem != nil })
        #expect(model.problem == "Counter-Strike 2 has no Windows prefix yet. Play it once first.")
        #expect(opened.value.isEmpty)

        // Counter-Strike 2 sits on the second disk; a stale compatdata in Steam's own library is not its prefix
        for library in [fixture.steam, fixture.external] {
            try FileManager.default.createDirectory(at: library.appending(path: "steamapps/compatdata/730/pfx/drive_c"),
                                                    withIntermediateDirectories: true)
        }
        model.problem = nil
        runner.perform(.openDriveC, on: cs2)
        #expect(await waitFor { !opened.value.isEmpty })
        let drive = try #require(opened.value.first)
        #expect(drive.lastPathComponent == "drive_c")
        #expect(drive.path(percentEncoded: false).contains("External/SteamLibrary/steamapps/compatdata/730/pfx"))
    }

    // MARK: Installer game

    private struct InstallerScene {
        let work: URL
        let folder: URL
        let loader: URL
        let game = Game(id: "installer:hades", source: .installer, name: "Hades", installed: true)
    }

    private func installerScene(_ label: String) throws -> InstallerScene {
        let work = try scratchDirectory(label)
        let folder = work.appending(path: "installs/hades")
        try FileManager.default.createDirectory(at: folder.appending(path: "pfx/drive_c"), withIntermediateDirectories: true)
        let loader = work.appending(path: "runner/bin/wine")
        try FileManager.default.createDirectory(at: loader.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: loader)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: loader.path(percentEncoded: false))
        try """
        #!/bin/sh
        export WINELOADER='\(loader.path(percentEncoded: false))'
        export WINESERVER='\(work.appending(path: "runner/bin/wineserver").path(percentEncoded: false))'
        export CX_ROOT='\(work.appending(path: "runner").path(percentEncoded: false))'
        """.write(to: folder.appending(path: "launch"), atomically: true, encoding: .utf8)
        return InstallerScene(work: work, folder: folder, loader: loader)
    }

    @Test("An installer game's tools run on its own prefix with the Wine its launcher names")
    func installerTools() async throws {
        let (model, fixture) = try await steamModel("wine-tools-installer")
        defer { fixture.remove() }
        let s = try installerScene("wine-tools-installer")
        defer { try? FileManager.default.removeItem(at: s.work) }
        model.installsFolder = s.work.appending(path: "installs")

        let tools = Box<[(WineTool, String, String?)]>([])
        let programs = Box<[(String, String)]>([])
        let tricks = Box<[([String], String)]>([])
        let opened = Box<[URL]>([])
        var runner = GameActionRunner(model: model, open: { opened.value.append($0) })
        runner.activity = activity(steam: fixture.steam)
        runner.launchTool = { tool, wine in
            let entry = (tool, wine.loader.path(percentEncoded: false), wine.environment["WINEPREFIX"])
            DispatchQueue.main.async { tools.value.append(entry) }
        }
        let setup = s.folder.appending(path: "pfx/drive_c/setup.exe")
        try Data().write(to: setup)
        runner.chooseProgram = { prefix in
            #expect(prefix.folder == s.folder)
            return setup
        }
        runner.runProgram = { program, wine, _ in
            let entry = (program.lastPathComponent, wine.loader.path(percentEncoded: false))
            DispatchQueue.main.async { programs.value.append(entry) }
        }
        runner.winetricksPrompt = { _ in "vcrun2022  corefonts" }
        runner.runWinetricks = { verbs, prefix, _ in
            let entry = (verbs, prefix.pfx.path(percentEncoded: false))
            await MainActor.run { tricks.value.append(entry) }
            return prefix.root.appending(path: PrefixTools.winetricksLogName)
        }

        runner.perform(.wineTool(.winecfg), on: s.game)
        runner.perform(.wineTool(.regedit), on: s.game)
        #expect(await waitFor { tools.value.count == 2 })
        #expect(Set(tools.value.map(\.0)) == [.winecfg, .regedit])
        #expect(tools.value.allSatisfy { $0.1 == s.loader.path(percentEncoded: false) })
        #expect(tools.value.allSatisfy { $0.2 == s.folder.appending(path: "pfx").path(percentEncoded: false) })

        runner.perform(.runInPrefix, on: s.game)
        #expect(await waitFor { programs.value.count == 1 })
        #expect(programs.value.first?.0 == "setup.exe")

        runner.perform(.winetricks, on: s.game)
        #expect(await waitFor { tricks.value.count == 1 })
        #expect(tricks.value.first?.0 == ["vcrun2022", "corefonts"])
        #expect(tricks.value.first?.1 == s.folder.appending(path: "pfx").path(percentEncoded: false))

        runner.perform(.openDriveC, on: s.game)
        #expect(await waitFor { opened.value.count == 1 })
        #expect(opened.value.first?.lastPathComponent == "drive_c")

        runner.perform(.showLog, on: s.game)
        #expect(await waitFor { model.problem == "Hades has no log yet." })
        let log = s.folder.appending(path: CrashLog.gameLog)
        try Data("started\n".utf8).write(to: log)
        runner.perform(.showLog, on: s.game)
        #expect(await waitFor { opened.value.count == 2 })
        #expect(opened.value.last?.lastPathComponent == CrashLog.gameLog)
    }

    @Test("Show Log opens the log the prefix wrote last, a crash report included")
    func latestLog() throws {
        let work = try scratchDirectory("wine-tools-log")
        defer { try? FileManager.default.removeItem(at: work) }
        let prefix = WinePrefix(appID: "hades", name: "Hades", library: SteamLibrary(root: work), lastUsed: nil,
                                source: .installer, folder: work.appending(path: "hades"))
        try FileManager.default.createDirectory(at: prefix.root, withIntermediateDirectories: true)
        let launchers = work.appending(path: "launchers")
        #expect(PrefixLog.latest(for: prefix, launchers: launchers) == nil)
        let game = prefix.root.appending(path: CrashLog.gameLog)
        let crash = prefix.root.appending(path: "\(CrashLog.namePrefix)2026-10-22.log")
        try Data("a".utf8).write(to: game)
        try Data("b".utf8).write(to: crash)
        let now = Date()
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-60)], ofItemAtPath: game.path(percentEncoded: false))
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: crash.path(percentEncoded: false))
        #expect(PrefixLog.latest(for: prefix, launchers: launchers)?.lastPathComponent == crash.lastPathComponent)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(60)], ofItemAtPath: game.path(percentEncoded: false))
        #expect(PrefixLog.latest(for: prefix, launchers: launchers)?.lastPathComponent == CrashLog.gameLog)
    }

    // MARK: SteamGameStop

    private func stopScene(_ label: String) throws -> SteamFixture {
        let fixture = try SteamFixture(label)
        try FileManager.default.createDirectory(at: fixture.external.appending(path: "steamapps/compatdata/730/pfx"),
                                                withIntermediateDirectories: true)
        return fixture
    }

    @Test("Stop finds the game's compatdata, or reports none, and acts on nothing when lsof is unclear")
    func stopOutcomes() async throws {
        let fixture = try stopScene("steam-stop-outcomes")
        defer { fixture.remove() }
        let files = SteamLocalFiles(userData: fixture.steam)
        let found = try await offMain { files.compatPrefix(appID: 730).map { GameProcesses.folderPrefix($0.root) } }
        let expected = GameProcesses.folderPrefix(fixture.external.appending(path: "steamapps/compatdata/730"))
        #expect(found == expected)

        var stop = SteamGameStop(files: files)
        stop.killServer = { _, _ in Issue.record("no wineserver -k"); return false }
        stop.clients = { _, _ in nil }
        let unknown = stop
        #expect(try await offMain { unknown.stop(appID: 730) } == .unknown)
        stop.clients = { _, _ in [] }
        let idle = stop
        #expect(try await offMain { idle.stop(appID: 730) } == .notRunning)
        #expect(try await offMain { idle.stop(appID: 1_245_620) } == .noPrefix)
    }

    @Test("Stop asks the prefix's own wineserver to end its clients when no spared process is one of them")
    func stopWithServer() async throws {
        let fixture = try stopScene("steam-stop-server")
        defer { fixture.remove() }
        let game = try Self.spawn("/bin/sleep", ["30"])
        defer { if game.isRunning { game.terminate() } }
        let killed = Probe<[String]>([])
        var stop = SteamGameStop(files: SteamLocalFiles(userData: fixture.steam))
        let pid = game.processIdentifier
        stop.clients = { _, _ in [pid] }
        stop.processes.spares = { _, _ in false }
        stop.server = { _ in URL(filePath: "/runner/bin/wineserver") }
        stop.killServer = { server, prefix in
            killed.value.append("\(server.path(percentEncoded: false)) \(prefix.pfx.path(percentEncoded: false))")
            return true
        }
        let ready = stop
        #expect(try await offMain { ready.stop(appID: 730) } == .stopped(1))
        #expect(killed.value.count == 1)
        #expect(killed.value.first?.hasSuffix("External/SteamLibrary/steamapps/compatdata/730/pfx") == true)
        #expect(game.isRunning, "-k does the ending; the game is not signalled on top of it")
    }

    @Test("A spared process in the prefix keeps it from wineserver -k: the others get signals, it gets none")
    func stopSparesListener() async throws {
        let fixture = try stopScene("steam-stop-spared")
        defer { fixture.remove() }
        let game = try Self.spawn("/bin/sleep", ["30"])
        let listener = try Self.spawn("/bin/sleep", ["30"])
        defer { [game, listener].forEach { if $0.isRunning { $0.terminate() } } }
        var stop = SteamGameStop(files: SteamLocalFiles(userData: fixture.steam))
        let pids = [game.processIdentifier, listener.processIdentifier]
        let spared = listener.processIdentifier
        stop.clients = { _, _ in pids }
        stop.processes.grace = .seconds(2)
        stop.processes.spares = { pid, port in pid == spared && port == 8765 }
        stop.server = { _ in URL(filePath: "/runner/bin/wineserver") }
        stop.killServer = { _, _ in Issue.record("-k would end the spared process too"); return true }
        let ready = stop
        #expect(try await offMain { ready.stop(appID: 730) } == .stopped(1))
        game.waitUntilExit()
        #expect(game.terminationReason == .uncaughtSignal)
        #expect(listener.isRunning)
    }

    @Test("Without a server to ask, or when it refuses, each client gets SIGTERM")
    func stopWithoutServer() async throws {
        let fixture = try stopScene("steam-stop-signal")
        defer { fixture.remove() }
        let game = try Self.spawn("/bin/sleep", ["30"])
        defer { if game.isRunning { game.terminate() } }
        var stop = SteamGameStop(files: SteamLocalFiles(userData: fixture.steam))
        let pid = game.processIdentifier
        stop.clients = { _, _ in [pid] }
        stop.processes.spares = { _, _ in false }
        stop.server = { _ in URL(filePath: "/runner/bin/wineserver") }
        stop.killServer = { _, _ in false }
        let ready = stop
        #expect(try await offMain { ready.stop(appID: 730) } == .stopped(1))
        game.waitUntilExit()
        #expect(game.terminationReason == .uncaughtSignal)
    }

    // MARK: Spared processes

    @Test("A process listening on the spared port is never signalled, and the listening socket is read through libproc")
    func listener() async throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #expect(fd >= 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) }
        }
        #expect(bound == 0)
        #expect(listen(fd, 1) == 0)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        let port = Int(UInt16(bigEndian: address.sin_port))
        #expect(port > 0)
        #expect(GameProcesses.listens(getpid(), port: port))
        #expect(!GameProcesses.listens(getpid(), port: port == 65_535 ? port - 1 : port + 1))
        #expect(GameProcesses.isSpared(getpid(), port: port))

        let other = try Self.spawn("/bin/sleep", ["30"])
        defer { if other.isRunning { other.terminate() } }
        var processes = GameProcesses(grace: .seconds(1))
        processes.spares = { _, _ in true }
        let pid = other.processIdentifier
        let ready = processes
        let result = try await offMain { () -> [Int] in
            let (signalled, killed) = ready.terminate([pid])
            return [signalled, killed]
        }
        #expect(result == [0, 0])
        #expect(other.isRunning)
    }
}
