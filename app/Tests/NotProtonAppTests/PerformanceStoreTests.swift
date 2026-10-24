import Foundation
import SQLite3
import Testing

@testable import NotProtonApp

// A launch folder as the run script and the frame counter write it, in a scratch folder
struct PerformanceFixture {
    let root: URL
    var store: PerformanceStore { PerformanceStore(folder: root.appending(path: "performance")) }

    init(_ label: String) throws {
        root = try scratchDirectory("perf-\(label)")
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    static let start = 1_790_000_000

    // seconds of samples from `start`, each at `fps` unless `frames` says otherwise
    @discardableResult
    func launch(_ name: String, appID: Int = 1_245_620, runner: String? = "26.3.0.39832", flavor: String? = "rosetta",
                backend: String? = "dxmt", display: String = "CrossOver 26.3 · DXMT", measure: String = "on",
                started: Int = start, ended: Int? = nil, seconds: Int = 0, fps: Int = 60,
                frames: (Int) -> Int? = { _ in nil }, frontmost: (Int) -> Bool = { _ in true },
                settings: [String] = [], pid: Int = 4242) throws -> URL {
        let folder = store.incoming.appending(path: name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var meta = ["app_id=\(appID)"]
        if let runner { meta.append("runner=\(runner)") }
        if let flavor { meta.append("flavor=\(flavor)") }
        if let backend { meta.append("backend=\(backend)") }
        meta += ["display=\(display)", "started=\(started)"]
        meta += settings.map { "setting=\($0)" }
        meta.append("measure=\(measure)")
        if let ended { meta.append("ended=\(ended)") }
        try Data((meta.joined(separator: "\n") + "\n").utf8).write(to: folder.appending(path: "session"))
        if seconds > 0 {
            var lines = ["# cartouche-fps 1 pid=\(pid) arch=x86_64"]
            for i in 0..<seconds {
                lines.append("\(started + 5 + i) \(frames(i) ?? fps) \(frontmost(i) ? 1 : 0) 2560 1440")
            }
            try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: folder.appending(path: "samples-\(pid)"))
        }
        return folder
    }
}

@Suite("Performance store")
struct PerformanceStoreTests {

    static let now = Date(timeIntervalSince1970: TimeInterval(PerformanceFixture.start + 7200))

    @Test("Background time is ignored: 2 minutes away in a 10-minute session leave 8 minutes, minus the first 30 seconds")
    func background() throws {
        let fixture = try PerformanceFixture("background")
        defer { fixture.remove() }
        let start = PerformanceFixture.start
        try fixture.launch("1245620-a-1", ended: start + 610, seconds: 600, frontmost: { !(200..<320).contains($0) })
        let added = try fixture.store.ingest(now: Self.now)
        let session = try #require(added.first)
        #expect(session.measured.seconds == 450)
        #expect(abs(session.measured.seconds - (8 * 60 - 30)) <= 5)
        #expect(session.measured.average == 60)
        #expect(session.duration == 610)
        let samples = try fixture.store.samples(session: session.id)
        #expect(samples.count == 600)
        #expect(samples.filter(\.counted).count == 450)
        #expect(samples.filter { !$0.sample.frontmost }.allSatisfy { !$0.counted })
        #expect(try fixture.store.sessions(appID: 1_245_620) == added)
    }

    @Test("The first 30 seconds and loading screens do not count")
    func warmUpAndLoading() throws {
        let fixture = try PerformanceFixture("warmup")
        defer { fixture.remove() }
        // Warm-up at 20 fps, a loading screen at 2 fps from 100 to 130, play at 60
        try fixture.launch("1-a-1", appID: 1, ended: PerformanceFixture.start + 300, seconds: 240,
                           frames: { $0 < 30 ? 20 : (100..<130).contains($0) ? 2 : nil })
        let session = try #require(try fixture.store.ingest(now: Self.now).first)
        #expect(session.measured.seconds == 240 - 30 - 30)
        #expect(session.measured.average == 60)
        #expect(session.measured.width == 2560 && session.measured.height == 1440)
    }

    @Test("The 1% low is the mean of the slowest 1% of counted seconds")
    func lowOnePercent() throws {
        let fixture = try PerformanceFixture("low")
        defer { fixture.remove() }
        // 1,000 counted seconds, 10 of them at 30 fps
        try fixture.launch("1-a-1", appID: 1, ended: PerformanceFixture.start + 1100, seconds: 1030,
                           frames: { (500..<510).contains($0) ? 30 : $0 == 600 ? 40 : nil })
        let session = try #require(try fixture.store.ingest(now: Self.now).first)
        #expect(session.measured.seconds == 1000)
        #expect(session.measured.low1 == 30)
        #expect(PlayStats.low1([60: 99, 12: 1]) == 12)
        #expect(PlayStats.low1([60: 50]) == 60)
        #expect(PlayStats.low1([:]) == nil)
    }

    @Test("A running game's folder waits, a killed run script's folder is read as ended at its last sample")
    func runningAndAbandoned() throws {
        let fixture = try PerformanceFixture("running")
        defer { fixture.remove() }
        let folder = try fixture.launch("1-a-1", appID: 1, seconds: 100)
        #expect(try fixture.store.ingest(now: Date()).isEmpty)
        #expect(FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)))
        let later = Date().addingTimeInterval(PerformanceIncoming.abandonedAfter + 60)
        let session = try #require(try fixture.store.ingest(now: later).first)
        #expect(session.ended == Date(timeIntervalSince1970: TimeInterval(PerformanceFixture.start + 5 + 99)))
        #expect(!FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)))
    }

    @Test("A session file written before the script recorded the setup still comes in")
    func noSetupInfo() throws {
        let fixture = try PerformanceFixture("no-setup")
        defer { fixture.remove() }
        let start = PerformanceFixture.start
        try fixture.launch("1-a-1", appID: 1, runner: nil, flavor: nil, backend: nil, display: "",
                           ended: start + 620, seconds: 600, fps: 45)
        let session = try #require(try fixture.store.ingest(now: Self.now).first)
        #expect(session.setup == PlaySetup(runnerID: PlaySetup.unknownRunnerID, translation: .rosetta, backend: nil))
        #expect(session.runnerName == PlaySetup.unknownRunnerID)
        #expect(session.duration == 620)
        #expect(session.measured.seconds == 570)
    }

    @Test("Each folder is read once, a folder that is not a launch is dropped, and helpers that present little are ignored")
    func onceAndInvalid() throws {
        let fixture = try PerformanceFixture("once")
        defer { fixture.remove() }
        let start = PerformanceFixture.start
        let folder = try fixture.launch("1-a-1", appID: 1, ended: start + 200, seconds: 150, settings: ["MTL_HUD_ENABLED=1", "DXMT_LOG=a=b"])
        var helper = ["# cartouche-fps 1 pid=7 arch=x86_64"]
        for i in 0..<150 { helper.append("\(start + 5 + i) 10 1 800 600") }
        try Data(helper.joined(separator: "\n").utf8).write(to: folder.appending(path: "samples-7"))
        let copy = fixture.root.appending(path: "copy")
        try FileManager.default.copyItem(at: folder, to: copy)
        let bad = fixture.store.incoming.appending(path: "garbage")
        try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
        try Data("app_id=x\n".utf8).write(to: bad.appending(path: "session"))

        let session = try #require(try fixture.store.ingest(now: Self.now).first)
        #expect(session.measured.average == 60)
        #expect(session.settings == ["MTL_HUD_ENABLED": "1", "DXMT_LOG": "a=b"])
        #expect(!FileManager.default.fileExists(atPath: bad.path(percentEncoded: false)))
        // The same folder again, as after a crash between the insert and the delete
        try FileManager.default.moveItem(at: copy, to: folder)
        #expect(try fixture.store.ingest(now: Self.now).isEmpty)
        #expect(try fixture.store.sessions().count == 1)
    }

    @Test("A session file still being written is a running launch, not garbage, until the folder is abandoned")
    func partialSessionIsRunning() throws {
        let fixture = try PerformanceFixture("partial")
        defer { fixture.remove() }
        let live = fixture.store.incoming.appending(path: "1245620-1-1")
        try FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
        try Data("app_id=1245620\nrunner=26.3.0.39832\n".utf8).write(to: live.appending(path: "session"))
        let empty = fixture.store.incoming.appending(path: "1245620-1-2")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try Data().write(to: empty.appending(path: "session"))

        let now = Date()
        #expect(PerformanceIncoming.read(live, now: now) == .running)
        #expect(PerformanceIncoming.read(empty, now: now) == .running)
        #expect(try fixture.store.ingest(now: now).isEmpty)
        #expect(FileManager.default.fileExists(atPath: live.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: empty.path(percentEncoded: false)))

        let later = now.addingTimeInterval(PerformanceIncoming.abandonedAfter + 60)
        #expect(PerformanceIncoming.read(live, now: later) == .invalid)
        _ = try fixture.store.ingest(now: later)
        #expect(!FileManager.default.fileExists(atPath: live.path(percentEncoded: false)))
    }

    @Test("A runner that refused the counter still records the session and its play time")
    func refused() throws {
        let fixture = try PerformanceFixture("refused")
        defer { fixture.remove() }
        try fixture.launch("1-a-1", appID: 1, flavor: "fex", backend: "dxvk", measure: "refused",
                           ended: PerformanceFixture.start + 900)
        let session = try #require(try fixture.store.ingest(now: Self.now).first)
        #expect(session.measurement == .refused)
        #expect(session.measured.seconds == 0)
        #expect(session.duration == 900)
        #expect(session.setup == PlaySetup(runnerID: "26.3.0.39832", translation: .fex, backend: .dxvk))
        #expect(try fixture.store.sessions(appID: 1).first?.measurement == .refused)
    }

    @Test("The counter's lines parse, and broken ones are skipped")
    func parse() {
        let text = "# cartouche-fps 1 pid=1 arch=arm64\n10 60 1 1280 720\n11 x 1 1 1\n12 59 0 1280 720\n13 -1 1 0 0\n"
        #expect(FrameSample.parse(text) == [
            FrameSample(time: 10, frames: 60, frontmost: true, width: 1280, height: 720),
            FrameSample(time: 12, frames: 59, frontmost: false, width: 1280, height: 720),
        ])
    }
}

@Suite("Play time averages")
struct PlayStatsTests {

    static func session(_ id: Int64, setup: PlaySetup, name: String = "CrossOver 26.3", hours: Double, fps: Double,
                        low: Int? = nil, startedAt: Int = 0, measurement: StoredSession.Measurement = .on) -> StoredSession {
        let seconds = Int((hours * 3600).rounded())
        let start = Date(timeIntervalSince1970: TimeInterval(1_790_000_000 + startedAt))
        var measured = PlayStats.Measured()
        if measurement == .on {
            var histogram = [Int(fps): seconds - seconds / 100]
            histogram[low ?? Int(fps), default: 0] += seconds / 100
            measured = PlayStats.Measured(seconds: seconds, frames: Int(fps * Double(seconds)), histogram: histogram)
        }
        return StoredSession(id: id, appID: 1_245_620, setup: setup, runnerName: name, started: start,
                             ended: start.addingTimeInterval(TimeInterval(seconds)), measurement: measurement,
                             measured: measured)
    }

    static let dxmt = PlaySetup(runnerID: "26.3.0.39832", translation: .rosetta, backend: .dxmt)
    static let d3dmetal = PlaySetup(runnerID: "26.3.0.39832", translation: .rosetta, backend: .d3dmetal)
    static let dxvk = PlaySetup(runnerID: "27.0.0.40921-fex", translation: .fex, backend: .dxvk)

    @Test("14.2 h at 56 fps and 1.1 h at 34 fps average 54 fps, not 45")
    func weighted() throws {
        let play = try #require(GamePlay.summarize([
            Self.session(1, setup: Self.dxmt, hours: 14.2, fps: 56),
            Self.session(2, setup: Self.d3dmetal, hours: 1.1, fps: 34, startedAt: 60_000),
        ]))
        let average = try #require(play.average)
        #expect(Int(average.rounded()) == 54)
        #expect(Int(((56.0 + 34.0) / 2).rounded()) == 45)
        #expect(PlayStats.weightedAverage([(56, 51_120), (34, 3_960)]).map { Int($0.rounded()) } == 54)
        #expect(PlayStats.weightedAverage([]) == nil)
    }

    @Test("The same through the SQLite store")
    func weightedStored() throws {
        let fixture = try PerformanceFixture("weighted")
        defer { fixture.remove() }
        try fixture.store.add(Self.session(0, setup: Self.dxmt, hours: 14.2, fps: 56), folder: "a")
        try fixture.store.add(Self.session(0, setup: Self.d3dmetal, hours: 1.1, fps: 34, startedAt: 60_000), folder: "b")
        let play = try #require(GamePlay.summarize(try fixture.store.sessions(appID: 1_245_620)))
        #expect(play.average.map { Int($0.rounded()) } == 54)
        #expect(play.setups.map(\.setup) == [Self.dxmt, Self.d3dmetal])
    }

    @Test("Each setup is summed over its sessions, best first, with play time and 1% low")
    func perSetup() throws {
        let play = try #require(GamePlay.summarize([
            Self.session(1, setup: Self.dxmt, hours: 2, fps: 50, low: 40),
            Self.session(2, setup: Self.dxmt, hours: 6, fps: 70, low: 50, startedAt: 10_000),
            Self.session(3, setup: Self.d3dmetal, hours: 1, fps: 75, low: 30, startedAt: 40_000),
            Self.session(4, setup: Self.dxvk, name: "CrossOver 2026 08 21 FEX", hours: 3, fps: 40, low: 20, startedAt: 50_000),
        ]))
        // DXMT has enough measured play to be the best, so it leads even at a lower average
        #expect(play.setups.map(\.setup) == [Self.dxmt, Self.d3dmetal, Self.dxvk])
        let dxmt = try #require(play.setups.first { $0.setup == Self.dxmt })
        #expect(dxmt.average == 65)
        #expect(dxmt.sessions == 2)
        #expect(dxmt.measuredSessions == 2)
        #expect(dxmt.meetsMinimumSample)
        #expect(dxmt.played == 8 * 3600)
        #expect(dxmt.lastPlayed == Date(timeIntervalSince1970: 1_790_010_000 + 6 * 3600))
        let d3dmetal = try #require(play.setups.first { $0.setup == Self.d3dmetal })
        #expect(d3dmetal.measuredSessions == 1)
        #expect(!d3dmetal.meetsMinimumSample)
        // 1% of 28,800 s is 288: the 72 at 40 fps, then 216 of the seconds at 50
        #expect(dxmt.low1 == 47.5)
        #expect(play.best?.setup == Self.dxmt)
        #expect(play.played == 12 * 3600)
        #expect(play.lastPlayed == Date(timeIntervalSince1970: 1_790_050_000 + 3 * 3600))
        #expect(play.setups.last?.runnerName == "CrossOver 2026 08 21 FEX")
        #expect(!play.measurementRefused)
    }

    @Test("A setup needs ten minutes over two sessions before it can be the best")
    func bestNeedsASample() throws {
        let play = try #require(GamePlay.summarize([
            // One long fast session is not enough on its own
            Self.session(1, setup: Self.dxvk, hours: 3, fps: 90),
            Self.session(2, setup: Self.dxmt, hours: 0.1, fps: 50, startedAt: 11_000),
            Self.session(3, setup: Self.dxmt, hours: 0.1, fps: 50, startedAt: 12_000),
        ]))
        #expect(play.setups.map(\.setup) == [Self.dxmt, Self.dxvk])
        #expect(play.best?.setup == Self.dxmt)
        // Two sessions of four minutes is not enough either, no best to call
        let short = try #require(GamePlay.summarize([
            Self.session(1, setup: Self.dxvk, hours: 3, fps: 90),
            Self.session(2, setup: Self.dxmt, hours: 0.05, fps: 50, startedAt: 11_000),
            Self.session(3, setup: Self.dxmt, hours: 0.05, fps: 50, startedAt: 12_000),
        ]))
        #expect(short.best == nil)
        #expect(short.setups.map(\.setup) == [Self.dxvk, Self.dxmt])
    }

    @Test("Ties on the average fall to the 1% low, then the longer sample")
    func bestTies() throws {
        let play = try #require(GamePlay.summarize([
            Self.session(1, setup: Self.dxmt, hours: 0.2, fps: 60, low: 50),
            Self.session(2, setup: Self.dxmt, hours: 0.2, fps: 60, low: 50, startedAt: 1_000),
            Self.session(3, setup: Self.dxvk, name: "FEX", hours: 0.2, fps: 60, low: 40, startedAt: 2_000),
            Self.session(4, setup: Self.dxvk, name: "FEX", hours: 0.2, fps: 60, low: 40, startedAt: 3_000),
            Self.session(5, setup: Self.d3dmetal, hours: 0.5, fps: 60, low: 50, startedAt: 4_000),
            Self.session(6, setup: Self.d3dmetal, hours: 0.5, fps: 60, low: 50, startedAt: 5_000),
        ]))
        // 60 fps each: D3DMetal measured over twice as long at the same 1% low,
        // DXMT's better 1% low beats DXVK
        #expect(play.setups.map(\.setup) == [Self.d3dmetal, Self.dxmt, Self.dxvk])
        #expect(play.best?.setup == Self.d3dmetal)
    }

    @Test("A database written before setup tracking gets the missing columns and fills them in")
    func migratesOldDatabase() throws {
        let fixture = try PerformanceFixture("migration")
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.store.folder, withIntermediateDirectories: true)
        var handle: OpaquePointer?
        #expect(sqlite3_open(fixture.store.database.path(percentEncoded: false), &handle) == SQLITE_OK)
        let db = try #require(handle)
        try exec(db, """
            CREATE TABLE sessions (id INTEGER PRIMARY KEY, folder TEXT, app_id INTEGER,
              runner_name TEXT, started REAL, ended REAL, measurement TEXT, measured_seconds INTEGER,
              frames INTEGER, average REAL, low1 REAL, histogram TEXT);
            CREATE TABLE samples (session INTEGER, time INTEGER, frames INTEGER, frontmost INTEGER);
            INSERT INTO sessions VALUES (1, 'old-a', 1, 'CrossOver 25', 1790000000, 1790000600,
              'on', 570, 25650, 45, 41, '45:570');
            INSERT INTO samples VALUES (1, 1790000005, 60, 1), (1, 1790000035, 55, 1),
              (1, 1790000036, 4, 1), (1, 1790000037, 55, 0);
            """)
        sqlite3_close(handle)
        handle = nil
        defer { sqlite3_close(handle) }

        let session = try #require(try fixture.store.sessions(appID: 1).first)
        // The only name the row has for its runner is the display name it kept
        #expect(session.setup == PlaySetup(runnerID: "CrossOver 25", translation: .rosetta, backend: nil))
        #expect(session.runnerName == "CrossOver 25")
        #expect(session.measured.seconds == 570)
        #expect(session.measured.average == 45)
        #expect(session.duration == 600)
        // The recount keeps the warm-up, the loading dip and the background second out
        #expect(try fixture.store.samples(session: 1).map { $0.counted } == [false, true, false, false])
        let version = try #require(try Database(fixture.store.database).query("PRAGMA user_version").first?.first)
        #expect(version == .int(Int64(PerformanceStore.schemaVersion)))
    }

    @Test("A refused runner counts play time, and the latest session says measurement was refused")
    func refused() throws {
        let play = try #require(GamePlay.summarize([
            Self.session(1, setup: Self.dxmt, hours: 2, fps: 60),
            Self.session(2, setup: Self.dxvk, hours: 1, fps: 0, startedAt: 9_000, measurement: .refused),
        ]))
        #expect(play.measurementRefused)
        #expect(play.average == 60)
        #expect(play.measuredSetups.map(\.setup) == [Self.dxmt])
        #expect(play.setups.count == 2)
        #expect(GamePlay.summarize([]) == nil)
    }
}

private func exec(_ db: OpaquePointer?, _ sql: String) throws {
    var error: UnsafeMutablePointer<CChar>?
    guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
        throw PerformanceStore.Failure(description: error.map { String(cString: $0) } ?? "sqlite error")
    }
}
