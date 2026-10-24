// The install's own record of every process that ran under it, written as it happens so a
// failure says exactly what died. macOS exposes exit codes only for the process we spawned
// ourselves (kqueue NOTE_EXITSTATUS is child-only), so the group's members are recorded with
// their name, command line and lifetime; the root's exit status is the setup's own.

import Foundation

public final class ProcessJournal: @unchecked Sendable {

    private struct Seen {
        let comm: String
        let since: Date
        var fromEnvironment: Bool
    }

    private let lock = NSLock()
    private var handle: FileHandle?
    private var known: [pid_t: Seen] = [:]
    private var envSeen: Set<pid_t> = []
    // Names of pids that have gone: their comm survives removal so the root's exit is named.
    private var names: [pid_t: String] = [:]
    private var finishedRoot = false

    public init?(file: URL) {
        guard FileManager.default.createFile(atPath: file.path(percentEncoded: false), contents: nil),
              let handle = try? FileHandle(forWritingTo: file) else { return nil }
        self.handle = handle
        note("process journal started")
    }

    // `descendants` is the caller's latest complete look at the root's own tree (updated every
    // tick); `environment` is the rarer full scan that also finds the prefix's other processes
    // (children wineserver spawned are not our descendants). A process matched only through the
    // environment is declared ended only when a full scan drops it.
    public func record(descendants: [ProcessGroup.Entry], environment: [ProcessGroup.Entry]?, at now: Date = Date()) {
        lock.withLock {
            if let environment {
                envSeen = Set(environment.map(\.pid))
                for entry in environment where known[entry.pid] == nil {
                    add(entry, at: now, fromEnvironment: true)
                }
            }
            let desc = Set(descendants.map(\.pid))
            for entry in descendants where known[entry.pid] == nil {
                add(entry, at: now, fromEnvironment: false)
            }
            for entry in descendants { known[entry.pid]?.fromEnvironment = false }
            let gone = known.filter { seen in seen.value.fromEnvironment ? !envSeen.contains(seen.key) : !desc.contains(seen.key) }
            for (pid, seen) in gone.sorted(by: { $0.key < $1.key }) {
                line("- \(pid) \(seen.comm) (\(Self.ellipsis(now.timeIntervalSince(seen.since))))", at: now)
                known[pid] = nil
            }
        }
    }

    public func note(_ text: String, at now: Date = Date()) {
        lock.withLock { line("# \(text)", at: now) }
    }

    // The root's status is the setup's: Inno's outer process forwards the inner setup's exit code.
    public func finish(root: pid_t, status: Int32, at now: Date = Date()) {
        lock.withLock {
            guard !finishedRoot else { return }
            finishedRoot = true
            let comm = names[root] ?? "setup"
            line("= \(root) \(comm) exited, status \(status)", at: now)
            for (pid, seen) in known.sorted(by: { $0.key < $1.key }) {
                line("! \(pid) \(seen.comm) still running at end", at: now)
            }
            try? handle?.synchronize()
        }
    }

    public func close() {
        lock.withLock {
            try? handle?.synchronize()
            try? handle?.close()
            handle = nil
        }
    }

    private func add(_ entry: ProcessGroup.Entry, at now: Date, fromEnvironment: Bool) {
        let comm = entry.comm.isEmpty ? "?" : entry.comm
        let args = ProcessGroup.commandLine(of: entry.pid)
        known[entry.pid] = Seen(comm: comm, since: now, fromEnvironment: fromEnvironment)
        names[entry.pid] = comm
        line("+ \(entry.pid) \(comm)\(args.map { " " + $0 } ?? "")", at: now)
    }

    private func line(_ text: String, at now: Date) {
        try? handle?.write(contentsOf: Data((Self.stamp(now) + "   " + text + "\n").utf8))
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    private static func stamp(_ date: Date) -> String { formatter.string(from: date) }

    private static func ellipsis(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return String(format: "%.0fs", seconds) }
        return String(format: "%dm%02ds", Int(seconds) / 60, Int(seconds) % 60)
    }
}
