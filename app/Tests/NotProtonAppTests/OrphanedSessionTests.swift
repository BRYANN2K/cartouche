import Foundation
import RetroArchKit
import Testing

@testable import NotProtonApp

// A session record left behind when Cartouche is killed mid-game: a process
// still there is picked up again, a gone one is counted to its heartbeat.
// The process table and the record file are the test's own; no real process
// or support folder is touched.
@Suite("Orphaned console sessions", .serialized)
@MainActor
struct OrphanedSessionTests {

    // The process table the test owns: pid -> process start, seconds since 1970
    final class FakeProcesses: @unchecked Sendable {
        private let lock = NSLock()
        private var starts: [pid_t: TimeInterval]

        init(_ starts: [pid_t: TimeInterval] = [:]) { self.starts = starts }

        func lookup(_ pid: pid_t) -> TimeInterval? {
            lock.lock()
            defer { lock.unlock() }
            return starts[pid]
        }

        // The process is gone; the pid is free for whoever takes it next
        func remove(_ pid: pid_t) {
            lock.lock()
            starts[pid] = nil
            lock.unlock()
        }
    }

    private func scene(_ label: String, table: FakeProcesses) async throws -> ConsoleScene {
        let scene = try await ConsoleScene(label)
        scene.center.sessions = SessionRecords(
            file: scene.work.appending(path: "support/console-session.json"),
            processStart: { pid in table.lookup(pid) })
        return scene
    }

    private func record(gameID: String, emulator: String? = nil,
                        pid: pid_t = 4242, processStarted: TimeInterval = 1_000,
                        started: Date, heartbeat: Date) -> ConsoleSessionRecord {
        ConsoleSessionRecord(gameID: gameID, emulator: emulator, pid: pid,
                             processStarted: processStarted, started: started, heartbeat: heartbeat)
    }

    private func fileExists(_ scene: ConsoleScene) -> Bool {
        FileManager.default.fileExists(atPath: scene.center.sessions.file.path(percentEncoded: false))
    }

    @Test("A record is written when the game starts, beat every minute, removed at Quit")
    func recordLifecycle() async throws {
        let table = FakeProcesses([4242: 1_000])
        let scene = try await scene("lifecycle", table: table)
        defer { scene.remove() }
        scene.center.heartbeatEvery = .milliseconds(40)
        _ = scene.useFakeRunner(picture: try ConsolePanelTests.screen("NO"), pid: 4242)
        let game = try await scene.addGame(console: "snes", name: "Cartouche Homebrew")

        await scene.center.play(game.id, reduceMotion: true)
        #expect(scene.center.problem == nil)
        let written = try #require(scene.center.sessions.read())
        #expect(written.gameID == game.id && written.emulator == nil && written.pid == 4242)
        #expect(written.processStarted == 1_000 && written.started == written.heartbeat)

        try await Task.sleep(for: .milliseconds(120))
        #expect(try #require(scene.center.sessions.read()).heartbeat > written.heartbeat)

        await scene.center.quit()
        #expect(!fileExists(scene))
        #expect(try #require(await scene.center.store.game(game.id)).playSeconds > 0)
    }

    @Test("Cartouche quitting ends the record too")
    func recordRemovedAtTermination() async throws {
        let table = FakeProcesses([4242: 1_000])
        let scene = try await scene("terminate", table: table)
        defer { scene.remove() }
        _ = scene.useFakeRunner(picture: try ConsolePanelTests.screen("NO"), pid: 4242)
        let game = try await scene.addGame(console: "snes", name: "Cartouche Homebrew")

        await scene.center.play(game.id, reduceMotion: true)
        #expect(scene.center.sessions.read() != nil)
        scene.center.endForTermination()
        #expect(!fileExists(scene))
    }

    @Test("A still-running session is picked up and counted when the process ends")
    func liveReattach() async throws {
        let table = FakeProcesses([4242: 1_000])
        let scene = try await scene("live", table: table)
        defer { scene.remove() }
        scene.center.heartbeatEvery = .milliseconds(40)
        let game = try await scene.addGame(console: "snes", name: "Cartouche Homebrew")
        let started = Date().addingTimeInterval(-300)
        let written = record(gameID: game.id, started: started, heartbeat: Date().addingTimeInterval(-30))
        scene.center.sessions.write(written)

        await scene.center.reattachOrphaned()
        #expect(scene.center.playing == Playing(gameID: game.id, phase: .playing))
        #expect(scene.center.runner is OrphanedRunner)
        #expect(scene.center.sessions.read() != nil, "the record is kept while the game runs")

        // The heartbeat goes on while the picked-up session is tracked
        try await Task.sleep(for: .milliseconds(120))
        #expect(try #require(scene.center.sessions.read()).heartbeat > written.heartbeat)

        // The process ends on its own
        table.remove(4242)
        let deadline = Date().addingTimeInterval(5)
        while scene.center.playing != nil, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        #expect(scene.center.playing == nil)
        let kept = try #require(await scene.center.store.game(game.id))
        #expect(kept.playSeconds >= 299, "the whole session is counted: \(kept.playSeconds)")
        #expect(!fileExists(scene))
        print("evidence: re-attached session counted \(kept.playSeconds)s after the process ended")
    }

    @Test("A standalone emulator session is picked up under its name")
    func liveReattachStandalone() async throws {
        let table = FakeProcesses([5151: 2_000])
        let scene = try await scene("live-standalone", table: table)
        defer { scene.remove() }
        let game = try await scene.addGame(console: "snes", name: "Cartouche Homebrew")
        scene.center.sessions.write(record(gameID: game.id, emulator: "Dolphin", pid: 5151,
                                           processStarted: 2_000,
                                           started: Date().addingTimeInterval(-120), heartbeat: Date()))

        await scene.center.reattachOrphaned()
        #expect(scene.center.playing == Playing(gameID: game.id, phase: .playing, emulator: "Dolphin"))

        table.remove(5151)
        let deadline = Date().addingTimeInterval(5)
        while scene.center.playing != nil, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        #expect(scene.center.playing == nil)
        #expect(try #require(await scene.center.store.game(game.id)).playSeconds >= 119)
    }

    @Test("A session whose process is gone is counted to the last heartbeat")
    func deadCountsToHeartbeat() async throws {
        let table = FakeProcesses()
        let scene = try await scene("dead", table: table)
        defer { scene.remove() }
        let game = try await scene.addGame(console: "snes", name: "Cartouche Homebrew")
        let started = Date().addingTimeInterval(-900)
        let heartbeat = Date().addingTimeInterval(-60)
        scene.center.sessions.write(record(gameID: game.id, started: started, heartbeat: heartbeat))

        await scene.center.reattachOrphaned()
        #expect(scene.center.playing == nil)
        #expect(scene.center.runner == nil)
        let kept = try #require(await scene.center.store.game(game.id))
        #expect(kept.playSeconds >= 839 && kept.playSeconds <= 841, "\(kept.playSeconds)")
        #expect(abs(kept.lastPlayed?.timeIntervalSince(heartbeat) ?? .infinity) < 0.001)
        #expect(!fileExists(scene))
        print("evidence: dead session counted \(kept.playSeconds)s to the heartbeat")
    }

    @Test("A pid taken by another process is not ours: counted to the heartbeat, never re-attached")
    func pidReusedIsNotReattached() async throws {
        // The pid answers, but its process started far later than the record's
        let table = FakeProcesses([4242: 9_999])
        let scene = try await scene("reused", table: table)
        defer { scene.remove() }
        let game = try await scene.addGame(console: "snes", name: "Cartouche Homebrew")
        let started = Date().addingTimeInterval(-600)
        let heartbeat = Date().addingTimeInterval(-45)
        scene.center.sessions.write(record(gameID: game.id, emulator: "Dolphin",
                                           started: started, heartbeat: heartbeat))

        await scene.center.reattachOrphaned()
        #expect(scene.center.playing == nil, "another process's pid is never picked up")
        let kept = try #require(await scene.center.store.game(game.id))
        #expect(kept.playSeconds >= 554 && kept.playSeconds <= 556, "\(kept.playSeconds)")
        #expect(!fileExists(scene))
    }

    @Test("A corrupt record is ignored and swept away")
    func corruptRecordIgnored() async throws {
        let table = FakeProcesses()
        let scene = try await scene("corrupt", table: table)
        defer { scene.remove() }
        let game = try await scene.addGame(console: "snes", name: "Cartouche Homebrew")
        let file = scene.center.sessions.file
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("this is not a session record".utf8).write(to: file)

        await scene.center.reattachOrphaned()
        #expect(scene.center.playing == nil)
        #expect(try #require(await scene.center.store.game(game.id)).playSeconds == 0)
        #expect(!fileExists(scene))
    }
}
