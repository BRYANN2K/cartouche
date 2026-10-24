import Foundation
import Testing

@testable import NotProtonApp

@Suite("Steam launch state")
struct SteamLaunchStateTests {
    private let started = Date(timeIntervalSince1970: 1_792_750_000)

    private func log(_ events: [String], at date: Date) -> String {
        let format = DateFormatter()
        format.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return events.map { "[\(format.string(from: date))] GameAction [AppID 2567870, \($0)" }.joined(separator: "\n")
    }

    @Test("Steam preparation, user prompts, completion and cancellation")
    func stages() {
        let pending = log(["ActionID 1] : LaunchApp changed task to ShowLaunchOption with \"\"",
                           "ActionID 1] : LaunchApp waiting for user response to ShowLaunchOption"], at: started)
        #expect(SteamActivityReader.launches(pending, since: started) == [2567870])
        for ending in ["changed task to Completed", "failed", "canceled", "cancelled", "aborted"] {
            let text = pending + "\n" + log(["ActionID 1] : LaunchApp \(ending)"], at: started)
            #expect(SteamActivityReader.launches(text, since: started).isEmpty)
        }
        #expect(SteamActivityReader.launches(pending, since: started.addingTimeInterval(60)).isEmpty)
        let overlap = pending + "\n" + log(["ActionID 2] : LaunchApp changed task to CreatingProcess",
                                            "ActionID 1] : LaunchApp changed task to Completed"], at: started)
        #expect(SteamActivityReader.launches(overlap, since: started) == [2567870])
    }

    @Test("Reads the live Steam session and clears preparation when Steam closes")
    func monitor() async throws {
        let fixture = try DownloadFixture("launch-state")
        defer { fixture.remove() }
        try log(["ActionID 1] : LaunchApp changed task to SynchronizingCloud"], at: started)
            .write(to: fixture.steam.appending(path: "logs/console_log.txt"), atomically: true, encoding: .utf8)
        let sessionStart = started
        var reader = fixture.reader
        reader.steamStartedAt = { sessionStart }
        let monitor = SteamDownloadMonitor(reader: reader, isSteamRunning: { true })
        let active = await monitor.poll()
        #expect(active.snapshot.launchingAppIDs == [2567870])
        #expect(active.interval == SteamDownloadMonitor.activeInterval)
        let closed = await SteamDownloadMonitor(reader: reader, isSteamRunning: { false }).poll()
        #expect(closed.snapshot.launchingAppIDs.isEmpty)
        #expect(closed.interval == SteamDownloadMonitor.closedInterval)
    }

    @Test("Preparing disables duplicate Play and setup; running exposes Stop Game")
    @MainActor
    func menu() async throws {
        let fixture = try SteamFixture("launch-menu")
        defer { fixture.remove() }
        try fixture.writeExport()
        let model = libraryModel(fixture, defaults: ScratchDefaults())
        await model.load()
        model.runners = [GameSetupTests.release]
        let game = try #require(model.game("steam:730"))
        let center = ActivityCenter(installs: InstallCenter(notifier: RecordingNotifier()),
                                    reader: SteamActivityReader(files: SteamLocalFiles(userData: fixture.steam)), control: RecordingControl(),
                                    notifier: RecordingActivityNotifier(), steamRunning: { false })
        center.apply(SteamActivitySnapshot(launchingAppIDs: [730]))
        let items = GameMenu.items(for: game, in: model, activity: center)
        #expect(items.first?.title == "Launching…")
        #expect(items.first?.disabled == true)
        #expect(items.first { $0.title == "Runner" }?.disabled == true)
        center.apply(SteamActivitySnapshot(runningAppID: 730, launchingAppIDs: [730]))
        #expect(center.steamLaunching.isEmpty)
        #expect(GameMenu.items(for: game, in: model, activity: center).first?.action == .stopGame)
        center.apply(SteamActivitySnapshot())
        #expect(GameMenu.items(for: game, in: model, activity: center).first?.action == .play)
    }
}
