import Foundation
import Testing

@testable import NotProtonApp

@Suite("Steam download progress between manifest writes")
struct SteamDownloadLiveTests {

    func live(_ fixture: DownloadFixture, appID: Int, done: Int64, total: Int64, state: String = "downloading") throws {
        let json = #"{"id":"00000000-0000-4000-8000-000000000000","appid":\#(appID),"state":"\#(state)","fraction":0.1,"progress":true,"done":\#(done),"total":\#(total)}"#
        try FileManager.default.createDirectory(at: fixture.support, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: fixture.support.appending(path: "steam-download-progress.json"))
    }

    @Test("Live bytes from Steam's overview replace the manifest's stale count while they are fresh")
    func fresh() throws {
        let fixture = try DownloadFixture("live"); defer { fixture.remove() }
        try fixture.manifest(2_556_990, "Beyond Good and Evil", flags: 1026, done: 123_069_936, total: 13_719_515_296)
        try live(fixture, appID: 2_556_990, done: 684_400_000, total: 13_719_515_296)
        let download = try #require(fixture.reader.read().downloads.first)
        #expect(download.bytesDone == 684_400_000)
        #expect(download.state == .downloading)
    }

    @Test("Without byte counts, Steam's overall percentage is applied to the manifest's size")
    func percent() throws {
        let fixture = try DownloadFixture("percent"); defer { fixture.remove() }
        try fixture.manifest(2_556_990, "Beyond Good and Evil", flags: 1026, done: 123_069_936, total: 10_000_000_000)
        let json = #"{"appid":2556990,"state":"downloading","fraction":0.81,"progress":true,"done":0,"total":0,"percent":81}"#
        try Data(json.utf8).write(to: fixture.support.appending(path: "steam-download-progress.json"))
        #expect(fixture.reader.read().downloads.first?.bytesDone == 8_100_000_000)
    }

    @Test("A stale or foreign reading leaves the manifest's count")
    func staleOrForeign() throws {
        let fixture = try DownloadFixture("stale"); defer { fixture.remove() }
        try fixture.manifest(2_556_990, "Beyond Good and Evil", flags: 1026, done: 123_069_936, total: 13_719_515_296)
        try live(fixture, appID: 291_550, done: 5, total: 10)
        #expect(fixture.reader.read().downloads.first?.bytesDone == 123_069_936)
        try live(fixture, appID: 2_556_990, done: 684_400_000, total: 13_719_515_296)
        var reader = fixture.reader
        reader.now = { Date().addingTimeInterval(60) }
        #expect(reader.read().downloads.first?.bytesDone == 123_069_936)
        #expect(SteamActivityReader.live(Data(#"{"appid":1,"done":5,"total":4,"progress":true}"#.utf8)) == nil)
    }

    @Test("A download Steam set aside for another one waits in the queue instead of failing")
    func suspendedForPriority() throws {
        let fixture = try DownloadFixture("priority"); defer { fixture.remove() }
        try fixture.manifest(2_556_990, "Beyond Good and Evil", flags: 1026, done: 1_703_989_312, total: 13_719_515_296, result: 4)
        #expect(fixture.reader.read().downloads.first?.state == .queued)
        try fixture.log(["AppID 2556990 update canceled : Priority (Suspended)",
                         "AppID 2556990 scheduler finished : staying in schedule (result Suspended, state 0x40a)"])
        #expect(fixture.reader.read().downloads.first?.state == .queued)
        #expect(SteamActivityReader.logStates("[x] AppID 7 update canceled : Suspended")[7] == .paused)
    }
}
