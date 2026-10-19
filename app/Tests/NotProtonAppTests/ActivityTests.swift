import Foundation
import Testing

@testable import NotProtonApp

// Steam's download state in a scratch folder: manifests with byte counts, the
// content log and registry.vdf. Nothing here reads the real Steam folder.
struct DownloadFixture {
    let root: URL
    var steam: URL { root.appending(path: "Steam") }
    var support: URL { root.appending(path: "Cartouche") }

    init(_ label: String) throws {
        root = try scratchDirectory("downloads-\(label)")
        for folder in ["steamapps", "logs", "config"] {
            try FileManager.default.createDirectory(at: steam.appending(path: folder), withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    }

    func manifest(_ appID: Int, _ name: String, flags: Int, done: Int64 = 0, total: Int64 = 0, result: Int = 0) throws {
        try """
        "AppState"
        {
        \t"appid"\t\t"\(appID)"
        \t"name"\t\t"\(name)"
        \t"StateFlags"\t\t"\(flags)"
        \t"installdir"\t\t"\(name)"
        \t"UpdateResult"\t\t"\(result)"
        \t"BytesToDownload"\t\t"\(total)"
        \t"BytesDownloaded"\t\t"\(done)"
        \t"BytesToStage"\t\t"\(total)"
        \t"BytesStaged"\t\t"\(done / 2)"
        }
        """.write(to: steam.appending(path: "steamapps/appmanifest_\(appID).acf"), atomically: true, encoding: .utf8)
    }

    func log(_ lines: [String]) throws {
        try lines.map { "[2026-10-19 21:04:11] \($0)" }.joined(separator: "\n")
            .write(to: steam.appending(path: "logs/content_log.txt"), atomically: true, encoding: .utf8)
    }

    func registry(running appID: Int) throws {
        try """
        "Registry"
        {
        \t"HKCU" { "Software" { "Valve" { "Steam" {
        \t\t"RunningAppID"\t\t"\(appID)"
        \t} } } }
        }
        """.write(to: steam.appending(path: "registry.vdf"), atomically: true, encoding: .utf8)
    }

    var reader: SteamActivityReader {
        SteamActivityReader(files: SteamLocalFiles(userData: steam))
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

@MainActor
final class RecordingActivityNotifier: ActivityNotifying {
    var posted: [String] = []
    func ready(name: String, appID: Int) { posted.append("ready \(name) \(appID)") }
    func downloadFailed(name: String, appID: Int, reason: String) { posted.append("failed \(name) \(reason)") }
}

@MainActor
final class RecordingControl: SteamDownloadControlling {
    var calls: [String] = []
    func pause(appID: Int) throws { calls.append("pause \(appID)") }
    func resume(appID: Int) throws { calls.append("resume \(appID)") }
    func cancel(appID: Int) throws { calls.append("cancel \(appID)") }
    func retry(appID: Int) throws { calls.append("retry \(appID)") }
}

let godOfWar = DownloadActivity(appID: 1_593_500, name: "God of War", state: .downloading,
                                bytesDone: 16_082_000_000, bytesTotal: 47_300_000_000)
let eldenRing = RunningGame(id: "steam:1245620", name: "Elden Ring", target: .steam(appID: 1_245_620), fps: 58)

@Suite("Activity slot")
struct ActivitySlotTests {

    // Every combination of the four kinds: the first present one in the order wins
    @Test("Playing beats installing beats downloads beats updates, for all 16 combinations")
    func priority() {
        let install = InstallActivity(title: "Sample Game", fraction: 0.4, stuck: false, waiting: 0)
        let update = UpdateActivity(id: "dxmt", title: "DXMT 0.80", kind: "Graphics")
        for mask in 0..<16 {
            let playing = mask & 1 != 0 ? eldenRing : nil
            let installing = mask & 2 != 0 ? install : nil
            let downloads = mask & 4 != 0 ? [godOfWar] : []
            let updates = mask & 8 != 0 ? [update] : []
            let slot = ActivitySlot.pick(playing: playing, install: installing, downloads: downloads, updates: updates)
            let expected: ActivitySlot? =
                if let playing { .playing(playing) }
                else if let installing { .installing(installing) }
                else if !downloads.isEmpty { .downloads(downloads) }
                else if let first = updates.first { .update(first) }
                else { nil }
            #expect(slot == expected, "mask \(mask)")
            // The status menu lists every kind present, whatever the slot shows
            let kinds = ActivityMenuSection.all(playing: playing, install: installing, downloads: downloads, updates: updates).map(\.kind)
            #expect(kinds.count == mask.nonzeroBitCount, "mask \(mask)")
        }
    }

    @Test("Nothing going on hides the slot")
    func nothing() {
        #expect(ActivitySlot.pick(playing: nil, install: nil, downloads: [], updates: []) == nil)
        #expect(ActivityMenuSection.all(playing: nil, install: nil, downloads: [], updates: []).isEmpty)
    }

    @Test("The ring: average progress, paused only when all are, failed wins")
    func summary() {
        var paused = godOfWar
        paused.state = .paused
        let other = DownloadActivity(appID: 1_172_470, name: "Apex Legends", state: .downloading, bytesDone: 30, bytesTotal: 100)
        let one = DownloadSummary(downloads: [godOfWar])
        #expect(one.percent == 34)
        #expect(one.mark == .downloading)
        #expect(one.label == "Downloading")
        #expect(one.detail == "34% of \(DownloadSummary.size(47_300_000_000))")
        #expect(DownloadSummary(downloads: [paused]).mark == .paused)
        #expect(DownloadSummary(downloads: [paused]).label == "Paused")
        let two = DownloadSummary(downloads: [paused, other])
        #expect(two.mark == .downloading)
        #expect(two.label == "Downloading 2 games")
        #expect(two.detail == "32%")
        var failed = other
        failed.state = .failed("Disk write failure")
        #expect(DownloadSummary(downloads: [godOfWar, failed]).mark == .failed)
        #expect(DownloadSummary(downloads: [godOfWar, failed]).label == "Download failed")
        #expect(godOfWar.cardStatus == "Downloading, 34%")
        #expect(paused.cardStatus == "Paused, 34%")
    }
}

@MainActor
@Suite("Activity center", .serialized)
struct ActivityCenterTests {

    func center(_ fixture: DownloadFixture, notifier: RecordingActivityNotifier = RecordingActivityNotifier(),
                control: RecordingControl = RecordingControl()) -> ActivityCenter {
        let center = ActivityCenter(installs: InstallCenter(notifier: RecordingNotifier()), reader: fixture.reader,
                                    control: control, notifier: notifier)
        center.isAppActive = { false }
        return center
    }

    @Test("Priority: a running game shows with its FPS and Quit, and the download stays in the status menu")
    func playingWhileDownloading() async throws {
        let fixture = try DownloadFixture("priority")
        defer { fixture.remove() }
        try fixture.manifest(1_245_620, "Elden Ring", flags: 4)
        try fixture.manifest(1_593_500, "God of War", flags: 1026, done: 16_082_000_000, total: 47_300_000_000)
        try fixture.registry(running: 1_245_620)
        let center = center(fixture)
        center.fps = { _ in 58 }
        await center.refresh()

        guard case .playing(let game) = center.slot else { Issue.record("slot is \(String(describing: center.slot))"); return }
        #expect(game.name == "Elden Ring")
        #expect(game.fps == 58)
        #expect(center.downloads.map(\.name) == ["God of War"])
        let menu = center.menuSections
        #expect(menu.map(\.kind) == [.playing, .downloads])
        #expect(menu[0].lines == [ActivityMenuSection.Line(title: "Elden Ring", detail: "58 fps")])
        #expect(menu[1].lines == [ActivityMenuSection.Line(title: "God of War", detail: "34%")])
    }

    @Test("Nothing to show: no game, download, install or update hides the slot")
    func nothingToShow() async throws {
        let fixture = try DownloadFixture("nothing")
        defer { fixture.remove() }
        try fixture.manifest(1_245_620, "Elden Ring", flags: 4)
        try fixture.registry(running: 0)
        let center = center(fixture)
        await center.refresh()
        #expect(center.slot == nil)
        #expect(center.menuSections.isEmpty)
    }

    @Test("A console session takes the slot as Playing on RetroArch, and Quit goes to its session")
    func console() async throws {
        let fixture = try DownloadFixture("console")
        defer { fixture.remove() }
        let center = center(fixture)
        var quit = 0
        center.quitConsole = { quit += 1 }
        center.consoleGame = RunningGame(id: "console:snes:1", name: "Super Metroid", target: .console)
        guard case .playing(let game) = center.slot else { Issue.record("no playing slot"); return }
        #expect(game.onRetroArch)
        await center.quitGame()
        #expect(quit == 1)
        #expect(center.slot == nil)
    }

    @Test("A download that finishes in the background posts ready to play once, and the library reloads")
    func finishes() async throws {
        let fixture = try DownloadFixture("finish")
        defer { fixture.remove() }
        try fixture.manifest(1_593_500, "God of War", flags: 1026, done: 40, total: 100)
        let notifier = RecordingActivityNotifier()
        let center = center(fixture, notifier: notifier)
        var reloaded: [Int] = []
        center.onDownloadFinished = { reloaded.append($0) }
        await center.refresh()
        #expect(center.downloads.count == 1)
        #expect(notifier.posted.isEmpty)

        try fixture.manifest(1_593_500, "God of War", flags: 4)
        await center.refresh()
        #expect(center.downloads.isEmpty)
        #expect(notifier.posted == ["ready God of War 1593500"])
        #expect(reloaded == [1_593_500])
        // The cover keeps its effect for the finish ring
        let game = Game.steam(1_593_500, name: "God of War", installed: true)
        #expect(center.reveal(for: game)?.finishedAt != nil)
        await center.refresh()
        #expect(notifier.posted.count == 1)
    }

    @Test("In the foreground there is no notification; the slot already shows it")
    func foreground() async throws {
        let fixture = try DownloadFixture("foreground")
        defer { fixture.remove() }
        try fixture.manifest(1_593_500, "God of War", flags: 1026, done: 40, total: 100)
        let notifier = RecordingActivityNotifier()
        let center = center(fixture, notifier: notifier)
        center.isAppActive = { true }
        await center.refresh()
        try fixture.manifest(1_593_500, "God of War", flags: 4)
        await center.refresh()
        #expect(notifier.posted.isEmpty)
    }

    @Test("A cancelled download, whose manifest goes away, posts nothing")
    func cancelled() async throws {
        let fixture = try DownloadFixture("cancelled")
        defer { fixture.remove() }
        try fixture.manifest(1_593_500, "God of War", flags: 1026, done: 40, total: 100)
        let notifier = RecordingActivityNotifier()
        let center = center(fixture, notifier: notifier)
        await center.refresh()
        try FileManager.default.removeItem(at: fixture.steam.appending(path: "steamapps/appmanifest_1593500.acf"))
        await center.refresh()
        #expect(center.downloads.isEmpty)
        #expect(notifier.posted.isEmpty)
    }

    @Test("A failure posts could not be downloaded with Steam's reason, once")
    func fails() async throws {
        let fixture = try DownloadFixture("fail")
        defer { fixture.remove() }
        try fixture.manifest(1_593_500, "God of War", flags: 1026, done: 40, total: 100)
        let notifier = RecordingActivityNotifier()
        let center = center(fixture, notifier: notifier)
        await center.refresh()
        try fixture.log(["AppID 1593500 update canceled : Disk write failure"])
        await center.refresh()
        #expect(center.downloads.first?.isFailed == true)
        #expect(notifier.posted == ["failed God of War Disk write failure"])
        await center.refresh()
        #expect(notifier.posted.count == 1)
    }

    @Test("The first finished download offers notifications after Cartouche's explanation, and only once")
    func offersNotifications() async throws {
        let fixture = try DownloadFixture("offer")
        defer { fixture.remove() }
        let tcc = FakeTCC()
        tcc.set(.notifications, .undetermined)
        let scratch = ScratchDefaults()
        let permissions = makeCenter(tcc, scratch)
        await permissions.refresh(.notifications)
        let flow = PermissionFlow(center: permissions)
        let center = center(fixture)
        center.permissionFlow = flow

        try fixture.manifest(1_593_500, "God of War", flags: 1026, done: 40, total: 100)
        await center.refresh()
        #expect(flow.asking == nil)
        try fixture.manifest(1_593_500, "God of War", flags: 4)
        await center.refresh()
        #expect(flow.asking?.permission == .notifications)
        #expect(tcc.requests.isEmpty)
        flow.notNow()

        try fixture.manifest(1_172_470, "Apex Legends", flags: 1026, done: 1, total: 100)
        await center.refresh()
        try fixture.manifest(1_172_470, "Apex Legends", flags: 4)
        await center.refresh()
        #expect(flow.asking == nil)
    }

    @Test("Pause from Cartouche: the command goes to Steam and the ring shows the paused symbol at once")
    func pause() async throws {
        let fixture = try DownloadFixture("pause")
        defer { fixture.remove() }
        try fixture.manifest(1_593_500, "God of War", flags: 1026, done: 40, total: 100)
        let control = RecordingControl()
        let center = center(fixture, control: control)
        await center.refresh()
        center.togglePause(1_593_500)
        #expect(control.calls == ["pause 1593500"])
        #expect(DownloadSummary(downloads: center.downloads).mark == .paused)
        // Steam's files have not caught up yet: the paused state holds
        await center.refresh()
        #expect(center.downloads.first?.state == .paused)
        // Steam's manifest shows the pause
        try fixture.manifest(1_593_500, "God of War", flags: 1538, done: 40, total: 100)
        await center.refresh()
        #expect(center.downloads.first?.state == .paused)
        center.togglePause(1_593_500)
        #expect(control.calls == ["pause 1593500", "resume 1593500"])
        #expect(center.downloads.first?.state == .downloading)
    }

    @Test("Cancel and Try Again go to Steam")
    func cancelAndRetry() async throws {
        let fixture = try DownloadFixture("cancel")
        defer { fixture.remove() }
        let control = RecordingControl()
        let center = center(fixture, control: control)
        center.cancel(1_593_500)
        center.retry(1_593_500)
        #expect(control.calls == ["cancel 1593500", "retry 1593500"])
    }
}

@Suite("Steam download state")
struct SteamDownloadStateTests {

    @Test("Manifests: progress from the byte counts, paused from bit 512, queued, installed, tools left out")
    func manifests() throws {
        let fixture = try DownloadFixture("manifests")
        defer { fixture.remove() }
        try fixture.manifest(1_593_500, "God of War", flags: 1026, done: 16_082_000_000, total: 47_300_000_000)
        try fixture.manifest(1_172_470, "Apex Legends", flags: 1538, done: 50, total: 200)
        try fixture.manifest(870_780, "Control", flags: 2, total: 1000)
        try fixture.manifest(1_245_620, "Elden Ring", flags: 4)
        try fixture.manifest(1_091_500, "Cyberpunk 2077", flags: 1030, done: 10, total: 20)
        try fixture.manifest(228_980, "Steamworks Common Redistributables", flags: 1026, done: 1, total: 2)
        let snapshot = fixture.reader.read()
        #expect(snapshot.downloads.map(\.appID) == [870_780, 1_091_500, 1_172_470, 1_593_500])
        let gow = try #require(snapshot.downloads.first { $0.appID == 1_593_500 })
        #expect(gow.state == .downloading)
        #expect(abs(gow.fraction - 0.34) < 0.001)
        #expect(snapshot.downloads.first { $0.appID == 1_172_470 }?.state == .paused)
        #expect(snapshot.downloads.first { $0.appID == 870_780 }?.state == .queued)
        // An update of an installed game is a download too
        #expect(snapshot.downloads.first { $0.appID == 1_091_500 }?.fraction == 0.5)
        #expect(snapshot.installed == [1_245_620])
        #expect(snapshot.runningAppID == nil)
    }

    @Test("The content log: a pause, a failure with its reason, and a restart")
    func contentLog() {
        let states = SteamActivityReader.logStates("""
        [2026-10-19 21:00:00] AppID 1593500 state changed : Update Required,Update Queued,Update Started,
        [2026-10-19 21:00:01] AppID 1593500 update started : download 0/47300000000, store 0/0, reuse 0/0, delta 0/0, stage 0/0
        [2026-10-19 21:04:11] AppID 1593500 update canceled : Suspended
        [2026-10-19 21:05:00] AppID 1172470 update canceled : Disk write failure
        [2026-10-19 21:06:00] AppID 870780 update canceled : Disk write failure
        [2026-10-19 21:07:00] AppID 870780 update started : download 0/10, store 0/0
        [2026-10-19 21:08:00] AppID 1245620 scheduler finished : removed from schedule (result Suspended, state 0x40a)
        """)
        #expect(states[1_593_500] == .paused)
        #expect(states[1_172_470] == .failed("Disk write failure"))
        #expect(states[870_780] == .running)
        #expect(states[1_245_620] == .paused)
    }

    @Test("A failure Steam wrote in UpdateResult is named")
    func updateResult() throws {
        let fixture = try DownloadFixture("result")
        defer { fixture.remove() }
        try fixture.manifest(1_593_500, "God of War", flags: 1026, done: 1, total: 2, result: 12)
        #expect(fixture.reader.read().downloads.first?.state == .failed("Not enough disk space"))
    }

    @Test("The running game from registry.vdf; 0 says nothing")
    func registry() throws {
        let fixture = try DownloadFixture("registry")
        defer { fixture.remove() }
        try fixture.manifest(1_245_620, "Elden Ring", flags: 4)
        try fixture.registry(running: 1_245_620)
        #expect(fixture.reader.read().runningAppID == 1_245_620)
        try fixture.registry(running: 0)
        #expect(fixture.reader.read().runningAppID == nil)
    }

    @Test("The log is read from its end only")
    func tail() throws {
        let fixture = try DownloadFixture("tail")
        defer { fixture.remove() }
        let url = fixture.steam.appending(path: "logs/content_log.txt")
        try (String(repeating: "x", count: 100_000) + "\nAppID 1 update canceled : Suspended\n").write(to: url, atomically: true, encoding: .utf8)
        let tail = SteamActivityReader.tail(of: url)
        #expect(tail.count <= 64 * 1024)
        #expect(tail.hasSuffix("Suspended\n"))
    }
}

@MainActor
@Suite("Steam download commands")
struct SteamDownloadCommandTests {

    @Test("Pause and Resume are written for the injected page, numbered, the last 16 kept")
    func commandFile() throws {
        let work = try scratchDirectory("commands")
        defer { try? FileManager.default.removeItem(at: work) }
        var opened: [URL] = []
        let commands = SteamDownloadCommands(file: work.appending(path: SteamDownloadCommandFile.fileName), open: { opened.append($0) })
        commands.now = { Date(timeIntervalSince1970: 1_790_000_000) }
        try commands.pause(appID: 1_593_500)
        try commands.resume(appID: 1_593_500)
        var doc = try JSONDecoder().decode(SteamDownloadCommandFile.self, from: Data(contentsOf: commands.file))
        #expect(doc.version == 1)
        #expect(doc.commands == [
            .init(id: 1, appid: 1_593_500, verb: .pause, at: 1_790_000_000),
            .init(id: 2, appid: 1_593_500, verb: .resume, at: 1_790_000_000),
        ])
        for _ in 0..<20 { try commands.pause(appID: 7) }
        doc = try JSONDecoder().decode(SteamDownloadCommandFile.self, from: Data(contentsOf: commands.file))
        #expect(doc.commands.count == 16)
        #expect(doc.commands.last?.id == 22)
        try commands.cancel(appID: 1_593_500)
        try commands.retry(appID: 1_593_500)
        #expect(opened.map(\.absoluteString) == ["steam://uninstall/1593500", "steam://install/1593500"])
    }
}

@Suite("Game processes", .serialized)
struct GameProcessTests {

    static func spawn(_ path: String, _ arguments: [String]) throws -> Process {
        let p = Process()
        p.executableURL = URL(filePath: path)
        p.arguments = arguments
        try p.run()
        return p
    }

    @Test("Quit ends the processes Steam tracks, their children and what runs from the game's folder, and no other")
    func quit() async throws {
        let work = try scratchDirectory("processes")
        defer { try? FileManager.default.removeItem(at: work) }
        let folder = work.appending(path: "steamapps/common/Sample Game")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let script = folder.appending(path: "game.sh")
        try Data("#!/bin/sh\n/bin/sleep 30\n".utf8).write(to: script)
        // A launcher Steam tracks, with a child of its own, like compat_run.sh and Wine
        let launcher = try Self.spawn("/bin/sh", ["-c", "/bin/sleep 30 & wait"])
        let fromFolder = try Self.spawn("/bin/sh", [script.path(percentEncoded: false)])
        let other = try Self.spawn("/bin/sleep", ["30"])
        defer { [launcher, fromFolder, other].forEach { if $0.isRunning { $0.terminate() } } }
        try await Task.sleep(for: .milliseconds(300))

        let log = """
        [2026-10-19 21:00:00] AppID 4242424 adding PID \(launcher.processIdentifier) as a tracked process "compat_run.sh"
        [2026-10-19 21:00:00] AppID 4242424 adding PID 99999 as a tracked process "old"
        [2026-10-19 21:00:01] AppID 4242424 no longer tracking PID 99999, exit code 0
        """
        let tracked = GameProcesses.tracked(inLog: log)
        #expect(tracked == [4_242_424: [launcher.processIdentifier]])

        let processes = GameProcesses(grace: .seconds(2))
        let pids = processes.pids(appID: 4_242_424, tracked: tracked[4_242_424] ?? [], installFolder: folder)
        #expect(pids.contains(launcher.processIdentifier))
        #expect(pids.contains(fromFolder.processIdentifier))
        #expect(pids.count >= 4, "the sleep children are found through their parents")
        #expect(!pids.contains(other.processIdentifier))
        #expect(!pids.contains(getpid()))

        #expect(processes.quit(appID: 4_242_424, tracked: tracked[4_242_424] ?? [], installFolder: folder) == pids.count)
        launcher.waitUntilExit()
        fromFolder.waitUntilExit()
        #expect(launcher.terminationReason == .uncaughtSignal)
        #expect(other.isRunning)
        #expect(processes.pids(appID: 4_242_424, tracked: [], installFolder: folder).isEmpty)
    }

    @Test("A game Steam tracks is the running game, while one of its processes lives")
    func running() async throws {
        let fixture = try DownloadFixture("running")
        defer { fixture.remove() }
        try fixture.manifest(1_245_620, "Elden Ring", flags: 4)
        let game = try Self.spawn("/bin/sleep", ["30"])
        defer { if game.isRunning { game.terminate() } }
        try "[2026-10-19 21:00:00] AppID 1245620 adding PID \(game.processIdentifier) as a tracked process \"eldenring.exe\"\n"
            .write(to: fixture.steam.appending(path: "logs/gameprocess_log.txt"), atomically: true, encoding: .utf8)
        #expect(fixture.reader.read().runningAppID == 1_245_620)
        #expect(fixture.reader.read().trackedPIDs == [game.processIdentifier])
        game.terminate()
        game.waitUntilExit()
        #expect(fixture.reader.read().runningAppID == nil)
    }

    @Test("Arguments and environment are read from KERN_PROCARGS2's layout")
    func parse() {
        var bytes: [UInt8] = [2, 0, 0, 0]
        bytes += Array("/bin/sleep".utf8) + [0, 0, 0]
        bytes += Array("sleep".utf8) + [0] + Array("30".utf8) + [0]
        bytes += Array("SteamGameId=12".utf8) + [0] + Array("A=b=c".utf8) + [0, 0]
        #expect(GameProcesses.parse(bytes) == GameProcesses.Info(
            path: "/bin/sleep", arguments: ["sleep", "30"], environment: ["SteamGameId": "12", "A": "b=c"]))
    }
}
