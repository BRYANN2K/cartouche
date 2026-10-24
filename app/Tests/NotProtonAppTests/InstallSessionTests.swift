import Foundation
import InstallerKit
import Testing

@testable import NotProtonApp

// The busy answer's three kinds, the menu they produce, and the prefix-scoped
// wineserver -k/-w the session actions run. Every probe stays off the main actor.
@MainActor
@Suite("Installer game session")
struct InstallSessionTests {

    private struct Scene {
        let work: URL
        let installs: URL
        let sockets: URL
        let folder: GameFolder
        let record: InstalledGame
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
        return Scene(work: work, installs: installs, sockets: work.appending(path: "wine-sockets"),
                     folder: folder, record: record,
                     game: try #require(model.game("installer:\(folder.root.lastPathComponent)")),
                     model: model)
    }

    private func center(_ s: Scene) -> InstallCenter {
        InstallCenter(engine: InstallEngine(installs: s.installs, runners: s.work.appending(path: "runners"),
                                            registry: { RunnerRegistry() }),
                      notifier: RecordingNotifier())
    }

    private func stubLsof(in dir: URL, body: String) throws -> String {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appending(path: "lsof")
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path(percentEncoded: false))
        return path.path(percentEncoded: false)
    }

    // An executable wineserver path exported the way GameLauncher writes it.
    @discardableResult
    private func launcher(in s: Scene) throws -> URL {
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
        return server
    }

    private func use(_ s: Scene, lsof: String, comm: String = "services.exe",
                     comms: [pid_t: String] = [:], infos: [pid_t: GameProcesses.Info] = [:],
                     children: [pid_t: [ProcessGroup.Entry]] = [:],
                     siblings: [(name: String, root: URL)] = []) async -> PrefixUse {
        let folder = s.folder, sockets = s.sockets, record = s.record
        return await Task.detached {
            PrefixStore.use(root: folder.root, pfx: folder.prefix, serverRoot: sockets, lsof: lsof,
                            own: (name: record.name, root: record.gameRoot), siblings: siblings,
                            commOf: { comms[$0] ?? comm }, infoOf: { infos[$0] },
                            childrenOf: { children[$0] ?? [] })
        }.value
    }

    private func info(_ path: String, _ argv: [String] = []) -> GameProcesses.Info {
        GameProcesses.Info(path: path, arguments: argv, environment: [:])
    }

    private func socket(_ s: Scene) throws -> URL {
        let dir = try #require(PrefixStore.serverDirectory(forPfx: s.folder.prefix, root: s.sockets))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("Services only is a session to end; a live client is named for the menu and blocks -k")
    func useKinds() async throws {
        let s = try scene("use-kinds")
        defer { try? FileManager.default.removeItem(at: s.work) }
        _ = try socket(s)
        let busy = try stubLsof(in: s.work, body: "echo 1234; echo 5678")
        let exe = s.record.gameRoot.appending(path: "game.exe").path(percentEncoded: false)

        #expect(await use(s, lsof: busy) == .sessionOnly)
        // The game's own leftover under its install folder: still the game running.
        #expect(await use(s, lsof: busy, comms: [1234: "game.exe"],
                    infos: [1234: info(exe, [exe])]) == .running(.game))
        // A store client in the same prefix keeps its real name and blocks -k.
        #expect(await use(s, lsof: busy, comms: [1234: "steam.exe"],
                    infos: [1234: info(#"C:\Steam\steam.exe"#)]) == .running(.store("Steam")))
        // A user-opened program is a real client, not a session helper.
        #expect(await use(s, lsof: busy, comms: [1234: "winecfg.exe"]) == .running(.program("winecfg")))
        // explorer /desktop is the session's own window; a user-opened Explorer is a client.
        #expect(await use(s, lsof: busy, comms: [1234: "explorer.exe"],
                    infos: [1234: info("", ["/desktop=shell,1600x900"])]) == .sessionOnly)
        #expect(await use(s, lsof: busy, comms: [1234: "explorer.exe"]) == .running(.program("explorer")))
        // Helpers by name, but wineserver still serves a real worker.
        #expect(await use(s, lsof: busy, comms: [1234: "services.exe", 5678: "wineserver"],
                    infos: [9: info(exe, [exe])],
                    children: [5678: [ProcessGroup.Entry(pid: 9, comm: "game.exe", descendant: true)]]) == .running(.game))
        // Nothing in the directory at all.
        #expect(await use(s, lsof: try stubLsof(in: s.work.appending(path: "other"), body: "exit 1")) == .free)
        // An answer with no pid in it is busy, never free.
        #expect(await use(s, lsof: try stubLsof(in: s.work.appending(path: "junk"), body: "echo junk"))
                == .running(.unknown))
    }

    @Test("Only services or the exited game's own leftovers let watchSession send -k")
    func endable() {
        #expect(PrefixUse.free.leftoversOnly == false)
        #expect(PrefixUse.sessionOnly.leftoversOnly)
        #expect(PrefixUse.running(.game).leftoversOnly)
        #expect(PrefixUse.running(.store("Steam")).leftoversOnly == false)
        #expect(PrefixUse.running(.program("winecfg")).leftoversOnly == false)
        #expect(PrefixUse.running(.unknown).leftoversOnly == false)
    }

    @Test("A session only Wine keeps up shows 'End Wine Session'; a running game shows 'Quit <name>'")
    func busySiblingLabel() async throws {
        let s = try scene("menu-session")
        defer { try? FileManager.default.removeItem(at: s.work) }
        let c = center(s)
        func item() -> GameMenuItem? {
            GameMenu.items(for: s.game, in: s.model, installs: c).first { $0.action == .endSession }
        }
        #expect(item() == nil)

        c.prefixUse = { _ in .sessionOnly }
        c.refreshBusy(for: [s.game], in: s.installs)
        #expect(await waitFor { c.sessionOnlyGames.contains(s.game.id) })
        #expect(item()?.title == "End Wine Session")
        #expect(item()?.disabled == false)
        let uninstall = GameMenu.items(for: s.game, in: s.model, installs: c).first { $0.action == .uninstall }
        #expect(uninstall?.disabled == true)

        c.prefixUse = { _ in .running(.game) }
        c.refreshBusy(for: [s.game], in: s.installs)
        #expect(await waitFor { !c.sessionOnlyGames.contains(s.game.id) && c.busyGames.contains(s.game.id) })
        #expect(item()?.title == "Quit Sample Game")

        // A store client or a user-opened program keeps its own name, not the game's.
        c.prefixUse = { _ in .running(.store("Steam")) }
        c.refreshBusy(for: [s.game], in: s.installs)
        #expect(await waitFor { c.busyClients[s.game.id] == .store("Steam") })
        #expect(item()?.title == "Quit Steam")

        c.prefixUse = { _ in .running(.program("winecfg")) }
        c.refreshBusy(for: [s.game], in: s.installs)
        #expect(await waitFor { c.busyClients[s.game.id] == .program("winecfg") })
        #expect(item()?.title == "Quit winecfg")

        // An unreadable busy session: the action still ends it, so the label says session.
        c.prefixUse = { _ in .running(.unknown) }
        c.refreshBusy(for: [s.game], in: s.installs)
        #expect(await waitFor { c.busyClients[s.game.id] == .unknown })
        #expect(item()?.title == "End Wine Session")

        c.prefixUse = { _ in .free }
        c.refreshBusy(for: [s.game], in: s.installs)
        #expect(await waitFor { !c.busyGames.contains(s.game.id) })
        #expect(item() == nil)
    }

    @Test("End Wine Session runs wineserver -k with the game's own prefix, then re-probes")
    func endSessionKills() async throws {
        let s = try scene("session-kill")
        defer { try? FileManager.default.removeItem(at: s.work) }
        let server = try launcher(in: s)
        let c = center(s)
        c.prefixUse = { _ in .sessionOnly }
        c.refreshBusy(for: [s.game], in: s.installs)
        #expect(await waitFor { c.sessionOnlyGames.contains(s.game.id) })

        let kills = Box<[(server: URL, env: [String: String])]>([])
        c.killServer = { server, env in kills.value.append((server, env)) }
        c.prefixUse = { _ in .free }
        c.endSession(for: s.game, in: s.installs)
        #expect(await waitFor { kills.value.count == 1 })
        #expect(kills.value.first?.server == server)
        #expect(kills.value.first?.env["WINEPREFIX"] == s.record.prefix)
        // The fresh answer frees the menu again.
        #expect(await waitFor { c.busyGames.isEmpty })
    }

    @Test("A launch that exits gets a prefix-scoped wineserver -w before the busy refresh")
    func watchSessionDrains() async throws {
        let s = try scene("session-watch")
        defer { try? FileManager.default.removeItem(at: s.work) }
        let server = try launcher(in: s)
        let c = center(s)
        let waits = Box<[(server: URL, env: [String: String], timeout: TimeInterval)]>([])
        c.waitServer = { server, env, timeout in waits.value.append((server, env, timeout)); return false }
        let kills = Box(0)
        c.killServer = { _, _ in kills.value += 1 }
        let probed = Box(0)
        c.prefixUse = { _ in probed.value += 1; return .free }

        let run = InstallRun(InstallLaunch(executable: "/bin/sh", arguments: ["-c", "exit 0"], environment: [:]))
        try run.start()
        c.watchSession(run, for: s.game, in: s.installs)
        #expect(await waitFor { waits.value.count == 1 })
        #expect(waits.value.first?.server == server)
        #expect(waits.value.first?.env["WINEPREFIX"] == s.record.prefix)
        #expect(waits.value.first?.timeout == WineSession.drain)
        #expect(await waitFor { probed.value > 0 })
        // The session drained on its own: nothing left for -k.
        try? await Task.sleep(for: .milliseconds(500))
        #expect(kills.value == 0)
    }

    @Test("A timed-out drain sends -k on Wine's services and the game's own leftovers")
    func watchSessionKillsLeftovers() async throws {
        let s = try scene("session-watch-kill")
        defer { try? FileManager.default.removeItem(at: s.work) }
        let server = try launcher(in: s)
        let c = center(s)
        c.waitServer = { _, _, _ in true }
        let kills = Box<[(server: URL, env: [String: String])]>([])
        c.killServer = { server, env in kills.value.append((server, env)) }

        // Only Wine's services hold the session: the leftover is ended.
        c.prefixUse = { _ in .sessionOnly }
        let first = InstallRun(InstallLaunch(executable: "/bin/sh", arguments: ["-c", "exit 0"], environment: [:]))
        try first.start()
        c.watchSession(first, for: s.game, in: s.installs)
        #expect(await waitFor { kills.value.count == 1 })
        #expect(kills.value.first?.server == server)
        #expect(kills.value.first?.env["WINEPREFIX"] == s.record.prefix)

        // The exited game's own leftover processes: ended too.
        c.prefixUse = { _ in .running(.game) }
        let second = InstallRun(InstallLaunch(executable: "/bin/sh", arguments: ["-c", "exit 0"], environment: [:]))
        try second.start()
        c.watchSession(second, for: s.game, in: s.installs)
        #expect(await waitFor { kills.value.count == 2 })
    }

    @Test("A timed-out drain never ends a session a store client, program or unknown holds")
    func watchSessionSparesClients() async throws {
        let s = try scene("session-watch-spare")
        defer { try? FileManager.default.removeItem(at: s.work) }
        _ = try launcher(in: s)
        let c = center(s)
        c.waitServer = { _, _, _ in true }
        let kills = Box(0)
        c.killServer = { _, _ in kills.value += 1 }

        for resident in [SessionResident.store("Steam"), .program("winecfg"), .unknown] {
            c.prefixUse = { _ in .running(resident) }
            let run = InstallRun(InstallLaunch(executable: "/bin/sh", arguments: ["-c", "exit 0"], environment: [:]))
            try run.start()
            c.watchSession(run, for: s.game, in: s.installs)
            // The session stays: busy with the client that holds it, never -k'd.
            #expect(await waitFor { c.busyClients[s.game.id] == resident })
        }
        try? await Task.sleep(for: .milliseconds(500))
        #expect(kills.value == 0)
    }

    @Test("Without a launcher's server, the record's runner names the session's wineserver")
    func sessionFromRunner() throws {
        let s = try scene("session-runner")
        defer { try? FileManager.default.removeItem(at: s.work) }
        let runners = s.work.appending(path: "runners")
        let runner = try fakeRunner(in: runners)
        var record = s.record
        record.runnerID = runner.id
        try InstalledGames.save(record, in: s.folder)

        let session = try #require(WineSession.of(folder: s.folder, runners: [runner], runnerRoot: runners))
        #expect(session.server.lastPathComponent.hasPrefix("wineserver"))
        #expect(session.prefix == s.folder.prefix)
        #expect(session.environment == ["WINEPREFIX": s.record.prefix])
    }

    @Test("Play reads Stop while the launcher runs; Stop ends the run and sends -k to the game's own prefix")
    func playBecomesStop() async throws {
        let s = try scene("session-stop")
        defer { try? FileManager.default.removeItem(at: s.work) }
        let server = try launcher(in: s)
        let c = center(s)
        c.waitServer = { _, _, _ in false }
        let kills = Box<[(server: URL, env: [String: String])]>([])
        c.killServer = { server, env in kills.value.append((server, env)) }
        c.prefixUse = { _ in .free }
        func first() -> GameMenuItem? { GameMenu.items(for: s.game, in: s.model, installs: c).first }
        #expect(first()?.action == .play)
        #expect(!GamePanelContent.isRunning(s.game, store: false, local: c.isPlaying(s.game)))

        let run = InstallRun(InstallLaunch(executable: "/bin/sh", arguments: ["-c", "sleep 30"], environment: [:]))
        try run.start()
        c.watchSession(run, for: s.game, in: s.installs)
        #expect(c.isPlaying(s.game))
        #expect(GamePanelContent.isRunning(s.game, store: false, local: c.isPlaying(s.game)))
        #expect(first()?.title == "Stop Game")
        #expect(first()?.action == .stopGame)
        #expect(first()?.shortcut == nil)

        GameActionRunner(model: s.model, installs: c).perform(.stopGame, on: s.game)
        #expect(await waitFor { !c.playingGames.contains(s.game.id) })
        #expect(await waitFor { !kills.value.isEmpty })
        #expect(kills.value.first?.server == server)
        #expect(kills.value.first?.env["WINEPREFIX"] == s.record.prefix)
        #expect(await waitFor { first()?.action == .play })
    }

    @Test("A crashed launcher ends its session after the grace period and Play comes back, the backtrace kept")
    func crashedGameIsNotRunning() async throws {
        let s = try scene("session-crash")
        defer { try? FileManager.default.removeItem(at: s.work) }
        let server = try launcher(in: s)
        let c = center(s)
        let waits = Box(0)
        c.waitServer = { _, _, _ in waits.value += 1; return true }
        let kills = Box<[URL]>([])
        // The crashed exe lingers in the prefix with no window, as winedbg leaves it, until -k.
        c.killServer = { server, _ in kills.value.append(server) }
        c.prefixUse = { _ in kills.value.isEmpty ? .running(.game) : .free }
        c.hasWindow = { _ in false }
        try Data("Unhandled exception: page fault on read access to 0x00000000 in 64-bit code\nBacktrace:\n".utf8)
            .write(to: s.folder.gameLog)

        let run = InstallRun(InstallLaunch(executable: "/bin/sh", arguments: ["-c", "exit 1"], environment: [:]))
        try run.start()
        c.watchSession(run, for: s.game, in: s.installs)
        #expect(await waitFor { kills.value.count == 1 })
        #expect(kills.value.first == server)
        #expect(await waitFor { !c.isPlaying(s.game) && !c.busyGames.contains(s.game.id) })
        #expect(GameMenu.items(for: s.game, in: s.model, installs: c).first?.action == .play)
        #expect(waits.value == 1)
        let crash = try #require(CrashLog.latest(in: s.folder.root))
        #expect(try String(contentsOf: crash, encoding: .utf8).contains("Backtrace:"))
    }

    @Test("A game still showing a window after its launcher exits keeps its session until the window is gone")
    func windowKeepsSession() async throws {
        let s = try scene("session-window")
        defer { try? FileManager.default.removeItem(at: s.work) }
        _ = try launcher(in: s)
        let c = center(s)
        let waits = Box(0)
        c.waitServer = { _, _, _ in
            waits.value += 1
            try? await Task.sleep(for: .milliseconds(50))
            return true
        }
        let kills = Box(0)
        c.killServer = { _, _ in kills.value += 1 }
        c.prefixUse = { _ in kills.value > 0 ? .free : .running(.game) }
        let window = Box(true)
        c.hasWindow = { _ in window.value }

        let run = InstallRun(InstallLaunch(executable: "/bin/sh", arguments: ["-c", "exit 0"], environment: [:]))
        try run.start()
        c.watchSession(run, for: s.game, in: s.installs)
        #expect(await waitFor { waits.value >= 3 })
        #expect(kills.value == 0)
        // Still running while its window shows: Stop stays offered.
        #expect(await waitFor { c.isPlaying(s.game) })
        window.value = false
        #expect(await waitFor { kills.value == 1 })
        #expect(await waitFor { !c.isPlaying(s.game) })
        // A clean exit leaves no crash report.
        #expect(CrashLog.latest(in: s.folder.root) == nil)
    }

    @Test("A game the probe finds running in its prefix reads Stop too, after a relaunch of Cartouche")
    func probedGameIsPlaying() async throws {
        let s = try scene("session-probed")
        defer { try? FileManager.default.removeItem(at: s.work) }
        let c = center(s)
        c.prefixUse = { _ in .running(.store("Steam")) }
        c.refreshBusy(for: [s.game], in: s.installs)
        #expect(await waitFor { c.busyClients[s.game.id] == .store("Steam") })
        #expect(!c.isPlaying(s.game))
        c.prefixUse = { _ in .running(.game) }
        c.refreshBusy(for: [s.game], in: s.installs)
        #expect(await waitFor { c.busyClients[s.game.id] == .game })
        #expect(c.isPlaying(s.game))
        #expect(GameMenu.items(for: s.game, in: s.model, installs: c).first?.action == .stopGame)
    }
}
