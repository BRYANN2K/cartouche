// Every process Cartouche stops is written down first, so a quit, a crash or the next launch
// can start it again. The JSON holds start times so a reused PID is never resumed by mistake.

import Darwin
import Foundation

struct PausedProcess: Codable, Equatable, Sendable {
    var pid: pid_t
    var started: Double
    var name: String
}

protocol ProcessSignalling: Sendable {
    func send(_ signal: Int32, to pid: pid_t) -> Bool
    // The start time of the live process, nil once it is gone
    func started(_ pid: pid_t) -> Double?
}

struct LiveSignaller: ProcessSignalling {
    func send(_ signal: Int32, to pid: pid_t) -> Bool { pid > 1 && pid != getpid() && kill(pid, signal) == 0 }
    func started(_ pid: pid_t) -> Double? { LiveResourceSource.process(pid)?.started }
}

// Outlives a crash of Cartouche: a shell waits for it to go and sends SIGCONT to the PIDs in the list.
@MainActor
protocol CrashGuard: AnyObject {
    func arm(list: URL)
}

@MainActor
final class ShellCrashGuard: CrashGuard {
    private var shell: Process?

    func arm(list: URL) {
        if let shell, shell.isRunning { return }
        do {
            shell = try Self.spawn(watching: getpid(), list: list)
        } catch {
            AppLog.note("paused-process guard did not start: \(error.localizedDescription)")
        }
    }

    nonisolated static func spawn(watching pid: pid_t, list: URL) throws -> Process {
        let script = """
            while /bin/kill -0 "$0" 2>/dev/null; do /bin/sleep 0.5; done
            [ -f "$1" ] || exit 0
            while read -r pid; do /bin/kill -CONT "$pid" 2>/dev/null; done < "$1"
            """
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", script, String(pid), list.path(percentEncoded: false)]
        try process.run()
        return process
    }
}

@MainActor
final class PausedProcesses {

    static var file: URL { SupportPaths.support.appending(path: "paused-processes.json") }

    let file: URL
    let signaller: any ProcessSignalling
    let crashGuard: (any CrashGuard)?
    private(set) var entries: [PausedProcess]

    var list: URL { file.deletingPathExtension().appendingPathExtension("pids") }
    var pids: Set<pid_t> { Set(entries.map(\.pid)) }

    init(file: URL = PausedProcesses.file, signaller: any ProcessSignalling = LiveSignaller(),
         crashGuard: (any CrashGuard)? = ShellCrashGuard()) {
        self.file = file
        self.signaller = signaller
        self.crashGuard = crashGuard
        entries = JSONFile.load([PausedProcess].self, from: file) ?? []
    }

    // Written before the signal: a crash between the two still leaves the PID on record.
    @discardableResult
    func pause(_ targets: [PausedProcess]) -> [pid_t] {
        let fresh = targets.filter { target in !entries.contains { $0.pid == target.pid } }
        guard !fresh.isEmpty else { return [] }
        entries += fresh
        save()
        crashGuard?.arm(list: list)
        var stopped: [pid_t] = []
        for target in fresh {
            if signaller.started(target.pid) == target.started, signaller.send(SIGSTOP, to: target.pid) {
                stopped.append(target.pid)
            } else {
                entries.removeAll { $0.pid == target.pid }
            }
        }
        save()
        if !stopped.isEmpty { AppLog.note("paused \(stopped.count) processes: \(fresh.map(\.name).joined(separator: ", "))") }
        return stopped
    }

    // Only a process that is still the one we stopped gets SIGCONT.
    @discardableResult
    func resume(_ pids: Set<pid_t>) -> [pid_t] {
        let chosen = entries.filter { pids.contains($0.pid) }
        guard !chosen.isEmpty else { return [] }
        var resumed: [pid_t] = []
        for entry in chosen where signaller.started(entry.pid) == entry.started {
            if signaller.send(SIGCONT, to: entry.pid) { resumed.append(entry.pid) }
        }
        entries.removeAll { pids.contains($0.pid) }
        save()
        if !resumed.isEmpty { AppLog.note("resumed \(resumed.count) paused processes") }
        return resumed
    }

    @discardableResult
    func resumeAll() -> [pid_t] { resume(pids) }

    // The previous run's leftovers, after a crash or a forced quit
    @discardableResult
    func resumeLeftovers() -> [pid_t] {
        entries = JSONFile.load([PausedProcess].self, from: file) ?? []
        return resumeAll()
    }

    func forget(_ pids: Set<pid_t>) {
        guard entries.contains(where: { pids.contains($0.pid) }) else { return }
        entries.removeAll { pids.contains($0.pid) }
        save()
    }

    // Only a pid whose recorded process is really gone; a kill that failed keeps its entry for resume
    func forgetGone(_ pids: Set<pid_t>) {
        forget(Set(entries.filter { pids.contains($0.pid) && signaller.started($0.pid) != $0.started }.map(\.pid)))
    }

    private func save() {
        let fm = FileManager.default
        if entries.isEmpty {
            try? fm.removeItem(at: file)
            try? fm.removeItem(at: list)
            return
        }
        try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(entries) { try? data.write(to: file, options: .atomic) }
        let lines = entries.map { "\($0.pid)\n" }.joined()
        try? Data(lines.utf8).write(to: list, options: .atomic)
    }
}
