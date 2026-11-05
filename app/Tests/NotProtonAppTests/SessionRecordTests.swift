import Foundation
import SQLite3
import Testing
@testable import NotProtonApp

// A clean A/B: each session records whether our options were on, their values, and what can bias it
@MainActor
@Suite("Session record")
struct SessionRecordTests {
    static let now = Date(timeIntervalSince1970: TimeInterval(PerformanceFixture.start + 7200))

    @Test("The run script's options and context, and the app's half, reach the stored session")
    func recorded() throws {
        let fixture = try PerformanceFixture("record")
        defer { fixture.remove() }
        let folder = try fixture.launch("1422450-1790000000-1", appID: 1_422_450, backend: "d3dmetal",
                                        ended: PerformanceFixture.start + 600, seconds: 120,
                                        settings: ["CARTOUCHE_FRAMEGEN=1", "CARTOUCHE_FRAMEGEN_INTERPOLATE=0", "CARTOUCHE_OVERLAY=std",
                                                   "D3DM_ENABLE_METALFX=0"])
        let session = folder.appending(path: "session")
        let extra = ["context=others_cpu_start=69", "context=swap_used_mb=2662", "context=power=battery",
                     "context=cartouche_running=2", "context=consent=1", "context=framegen=on", "context=memory_pressure="]
        try Data(((try String(contentsOf: session, encoding: .utf8)) + extra.joined(separator: "\n") + "\n").utf8).write(to: session)
        try Data("others_cpu_avg=41\nthermal_max=nominal\ndisplay=1710×1112 @ 120 Hz\n".utf8)
            .write(to: folder.appending(path: PerformanceIncoming.appContextFile))
        try fixture.store.ingest(now: Self.now)
        let stored = try #require(try fixture.store.sessions(appID: 1_422_450).first)
        #expect(stored.settings["CARTOUCHE_FRAMEGEN"] == "1" && stored.settings["CARTOUCHE_OVERLAY"] == "std")
        #expect(stored.context["others_cpu_start"] == "69" && stored.context["others_cpu_avg"] == "41")
        #expect(stored.context["display"] == "1710×1112 @ 120 Hz" && stored.context["framegen"] == "on")
        #expect(stored.context["memory_pressure"] == nil, "an empty value is not kept")
        #expect(stored.setup.options == true)
    }

    @Test("Options: the library in, or an upscaling variable on; unknown for an old session with neither")
    func optionsRule() {
        #expect(PlaySetup.options(settings: [:], context: ["framegen": "on"]) == true)
        #expect(PlaySetup.options(settings: ["CARTOUCHE_FRAMEGEN": "1"], context: ["framegen": "refused"]) == false)
        #expect(PlaySetup.options(settings: [:], context: ["framegen": "off"]) == false)
        #expect(PlaySetup.options(settings: ["D3DM_ENABLE_METALFX": "1"], context: ["framegen": "off"]) == true)
        #expect(PlaySetup.options(settings: ["D3DM_ENABLE_METALFX": "1"], context: [:]) == true, "the 2026-10-25 sessions")
        #expect(PlaySetup.options(settings: ["ROSETTA_ADVERTISE_AVX": "1"], context: [:]) == nil)
    }

    @Test("With and without our options, the same runner reads as two setups to compare")
    func abSplit() throws {
        let base = PlaySetup(runnerID: "cx", translation: .rosetta, backend: .d3dmetal)
        var with = base
        with.options = true
        var without = base
        without.options = false
        let play = try #require(GamePlay.summarize([
            PlayStatsTests.session(1, setup: without, hours: 1, fps: 47),
            PlayStatsTests.session(2, setup: with, hours: 1, fps: 61, startedAt: 9_000),
        ]))
        #expect(play.setups.count == 2)
        #expect(Set(play.setups.map { $0.setup.options }) == [true, false])
    }

    @Test("A database from before the context gets the column; its rows read with no context")
    func migration() throws {
        let fixture = try PerformanceFixture("context-migration")
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.store.folder, withIntermediateDirectories: true)
        var handle: OpaquePointer?
        #expect(sqlite3_open(fixture.store.database.path(percentEncoded: false), &handle) == SQLITE_OK)
        let old = PerformanceStore.schema.replacingOccurrences(of: #"\n\s*context TEXT NOT NULL DEFAULT '\{\}',"#, with: "",
                                                               options: .regularExpression)
        #expect(old != PerformanceStore.schema)
        for sql in [old, "PRAGMA user_version = 2", """
            INSERT INTO sessions (folder, app_id, runner, translation, backend, runner_name, settings, started, ended, measurement,
              measured_seconds, frames, histogram) VALUES ('old', 1422450, 'cx', 'rosetta', 'd3dmetal', 'Cartouche Wine 26.3',
              '{"ROSETTA_ADVERTISE_AVX":"1"}', 1790000000, 1790000600, 'on', 570, 34000, '60:570')
            """] {
            #expect(sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK)
        }
        sqlite3_close(handle)
        let session = try #require(try fixture.store.sessions(appID: 1_422_450).first)
        #expect(session.context.isEmpty && session.setup.options == nil)
        #expect(session.settings == ["ROSETTA_ADVERTISE_AVX": "1"])
        let version = try #require(try Database(fixture.store.database).query("PRAGMA user_version").first?.first)
        #expect(version == .int(3))
    }

    @Test("The app writes its half into the running launch only")
    func appHalf() throws {
        let fixture = try PerformanceFixture("app-context")
        defer { fixture.remove() }
        let running = try fixture.launch("1-1790000000-1", started: PerformanceFixture.start)
        let ended = try fixture.launch("1-1790000000-2", started: PerformanceFixture.start, ended: PerformanceFixture.start + 60)
        let stale = try fixture.launch("1-1700000000-3", started: 1_700_000_000)
        var recorder = SessionContextRecorder(display: "1710×1112 @ 120 Hz")
        recorder.add(othersCPU: 40, thermal: 0)
        recorder.add(othersCPU: 30, thermal: 2)
        #expect(recorder.lines == ["others_cpu_avg=35", "thermal_max=serious", "display=1710×1112 @ 120 Hz"])
        SessionContextRecorder.write(recorder.lines, incoming: fixture.store.incoming,
                                     since: Date(timeIntervalSince1970: TimeInterval(PerformanceFixture.start - 120)))
        let file = PerformanceIncoming.appContextFile
        #expect(FileManager.default.fileExists(atPath: running.appending(path: file).path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: ended.appending(path: file).path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: stale.appending(path: file).path(percentEncoded: false)))
    }

    @Test("Compare Setups: « Cartouche Options: On », the values, then the context on one line")
    func facts() {
        let context = ["consent": "0", "framegen": "refused", "others_cpu_start": "69", "others_cpu_avg": "41",
                       "swap_used_mb": "2662", "power": "battery", "cartouche_running": "2", "display": "1710×1112 @ 120 Hz"]
        #expect(SessionFacts.options(false, context: context) == "Cartouche Options: Off · Library refused · Cartouche Engine Off")
        #expect(SessionFacts.values(["CARTOUCHE_FRAMEGEN": "1", "D3DM_ENABLE_METALFX": "1", "WINEMSYNC": "1"])
                == "CARTOUCHE_FRAMEGEN=1 · D3DM_ENABLE_METALFX=1")
        #expect(SessionFacts.context(context)
                == "Other apps 69% CPU (41% on average) · Swap \((2662.0 / 1024).formatted(.number.precision(.fractionLength(1)))) GB"
                + " · On battery · 1710×1112 @ 120 Hz · 2 Cartouche running")
        #expect(SessionFacts.context([:]) == nil)
    }

    @Test("The launch carries the consent for the record, under an anti-cheat too")
    func consentMarker() {
        let choice = GameSetupChoice(graphics: .d3dmetal, translation: .rosetta)
        let availability = BackendAvailability(d3dMetalRunners: [GameSetupTests.release.id])
        func env(protected: Bool) -> [String: String] {
            GameSetupResolver.resolve(choice, runners: [GameSetupTests.release], availability: availability,
                                      profile: LaunchProfile(settings: OverlaySettings(), protected: protected, dlss: false)).setup.environment
        }
        #expect(env(protected: true)["CARTOUCHE_SHARPENING"] == "0")
        #expect(env(protected: false)["CARTOUCHE_SHARPENING"] == "1")
    }
}
