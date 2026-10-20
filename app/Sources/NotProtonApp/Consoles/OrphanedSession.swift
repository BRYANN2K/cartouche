// A session record survives a killed Cartouche; a pid is trusted only with its process start, and a found process is never signaled, only asked to quit.

import AppKit
import Darwin
import Foundation
import RetroArchKit

struct ConsoleSessionRecord: Codable, Equatable, Sendable {
    var gameID: String
    // The standalone emulator it plays in; nil for RetroArch
    var emulator: String?
    var pid: Int32
    // Seconds since 1970; distinguishes the process from whoever takes the pid next.
    var processStarted: TimeInterval
    var started: Date
    // One beat a minute while Cartouche lived.
    var heartbeat: Date
}

struct SessionRecords: Sendable {

    var file: URL
    // Seconds since 1970; nil when the process is gone or not ours to look at.
    var processStart: @Sendable (pid_t) -> TimeInterval? = SessionRecords.processStarted
    var now: @Sendable () -> Date = { Date() }
    var tolerance: TimeInterval = 0.5

    func read() -> ConsoleSessionRecord? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(ConsoleSessionRecord.self, from: data)
    }

    func clearUnreadable() {
        guard FileManager.default.fileExists(atPath: file.path(percentEncoded: false)),
              read() == nil else { return }
        try? FileManager.default.removeItem(at: file)
    }

    func write(_ record: ConsoleSessionRecord) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(record).write(to: file, options: .atomic)
    }

    func heartbeat() {
        guard var record = read() else { return }
        record.heartbeat = now()
        write(record)
    }

    func clear() {
        try? FileManager.default.removeItem(at: file)
    }

    // Same pid AND same start; anything else is not ours - gone or someone else holding the pid.
    func isSameProcess(_ record: ConsoleSessionRecord) -> Bool {
        guard let start = processStart(record.pid) else { return false }
        return abs(start - record.processStarted) < tolerance
    }

    // A zombie still answers kill(0); only a reaped or gone pid is empty here
    static func processStarted(_ pid: pid_t) -> TimeInterval? {
        guard kill(pid, 0) == 0 else { return nil }
        var info = proc_bsdinfo()
        let size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        guard size > 0, info.pbi_status != UInt32(SZOMB) else { return nil }
        return TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1e6
    }
}

// Cartouche did not start it and cannot drive it: only ever asked its own Quit, never sent a signal.
actor OrphanedRunner: ConsoleRunning {

    let record: ConsoleSessionRecord
    let sessions: SessionRecords
    var quitGrace: Duration = .seconds(5)

    init(record: ConsoleSessionRecord, sessions: SessionRecords) {
        self.record = record
        self.sessions = sessions
    }

    var processIdentifier: Int32? { record.pid }

    func play(_ request: PlayRequest) async throws { throw RetroArchSessionError.notRunning }
    func setLook(_ look: ConsoleLook) async throws {}
    func setLowerInputLag(_ on: Bool) async throws {}
    func setHardcore(_ on: Bool) async throws {}
    func setDisc(_ disc: Int) async throws {}

    // RetroArch writes its auto state, an emulator saves; if it stays, the session is still counted.
    func quit() async -> PlayReport {
        // The pid may belong to another app by now: only the same process is asked to quit
        if sessions.isSameProcess(record) {
            _ = NSRunningApplication(processIdentifier: record.pid)?.terminate()
        }
        let deadline = ContinuousClock.now + quitGrace
        while sessions.isSameProcess(record), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        return report(way: sessions.isSameProcess(record) ? .notRunning : .quit)
    }

    // The process gone — or its pid taken by another — ends the session
    func ended() async -> PlayReport? {
        sessions.isSameProcess(record) ? nil : report(way: .quit)
    }

    // A standalone emulator is the user's own app and keeps running.
    func leaveForTermination() async -> PlayReport {
        if record.emulator == nil { return await quit() }
        return report(way: .notRunning)
    }

    private func report(way: StopReport.Way) -> PlayReport {
        let played = Duration.seconds(sessions.now().timeIntervalSince(record.started))
        return PlayReport(stop: StopReport(way: way, duration: .zero), played: played)
    }
}
