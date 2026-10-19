// Finds and quits a running Steam game. Steam writes the processes it tracks for
// a game to logs/gameprocess_log.txt; the game's processes are those, their
// children, and anything started from the game's install folder. macOS no
// longer shows another process's environment, so SteamGameId is a last resort.

import Darwin
import Foundation

struct GameProcesses: Sendable {

    // How long a game gets to close after SIGTERM before it is killed
    var grace: Duration = .seconds(5)
    // Every PID to look at; tests pass their own children
    var candidates: @Sendable () -> [pid_t] = GameProcesses.allProcesses

    struct Info: Equatable, Sendable {
        var path: String
        var arguments: [String]
        var environment: [String: String]
    }

    // The processes of this game. Steam itself and Cartouche never are.
    func pids(appID: Int, tracked: [pid_t] = [], installFolder: URL? = nil) -> [pid_t] {
        let me = getpid()
        let all = candidates().filter { $0 > 1 && $0 != me }
        var found = Set(tracked.filter(Self.isAlive))
        let folder = installFolder.map { Self.folderPrefix($0) }
        let wanted = String(appID)
        for pid in all where !found.contains(pid) {
            guard let info = Self.info(of: pid) else { continue }
            if info.environment["SteamGameId"] == wanted || info.environment["SteamAppId"] == wanted {
                found.insert(pid)
            } else if let folder, info.path.hasPrefix(folder) || info.arguments.contains(where: { $0.hasPrefix(folder) }) {
                found.insert(pid)
            }
        }
        // Children of the game, like the Wine processes compat_run.sh starts
        var parents = Dictionary(uniqueKeysWithValues: all.map { ($0, Self.parent(of: $0)) })
        for pid in found where parents[pid] == nil { parents[pid] = Self.parent(of: pid) }
        var grew = true
        while grew {
            grew = false
            for (pid, parent) in parents where !found.contains(pid) && parent.map(found.contains) == true {
                found.insert(pid)
                grew = true
            }
        }
        found.remove(me)
        return found.sorted()
    }

    // SIGTERM, then SIGKILL for what is left after the grace period. Returns how many were asked to quit.
    @discardableResult
    func quit(appID: Int, tracked: [pid_t] = [], installFolder: URL? = nil) -> Int {
        let targets = pids(appID: appID, tracked: tracked, installFolder: installFolder)
        guard !targets.isEmpty else { return 0 }
        for pid in targets { kill(pid, SIGTERM) }
        let deadline = ContinuousClock.now + grace
        var alive = targets
        while !alive.isEmpty && ContinuousClock.now < deadline {
            usleep(100_000)
            alive = alive.filter(Self.isAlive)
        }
        for pid in alive { kill(pid, SIGKILL) }
        AppLog.note("quit game \(appID): \(targets.count) processes, \(alive.count) killed")
        return targets.count
    }

    static func folderPrefix(_ url: URL) -> String {
        let path = url.standardizedFileURL.path(percentEncoded: false)
        return path.hasSuffix("/") ? path : path + "/"
    }

    static func isAlive(_ pid: pid_t) -> Bool {
        // A zombie still answers kill(0); only a reaped or gone process says ESRCH
        guard kill(pid, 0) == 0 else { return false }
        var info = proc_bsdinfo()
        let size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        return size > 0 && info.pbi_status != UInt32(SZOMB)
    }

    static func parent(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        return size > 0 ? pid_t(info.pbi_ppid) : nil
    }

    static func allProcesses() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard filled > 0 else { return [] }
        return Array(pids.prefix(Int(filled)))
    }

    // The executable, arguments and, where macOS still shows it, environment of a
    // process, through KERN_PROCARGS2. Only the user's own processes answer.
    static func info(of pid: pid_t) -> Info? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return parse(Array(buffer.prefix(size)))
    }

    // argc, the executable path, padding, argc arguments, then the environment
    static func parse(_ bytes: [UInt8]) -> Info? {
        guard bytes.count > 4 else { return nil }
        let argc = bytes.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        var i = 4
        func string() -> String? {
            guard i < bytes.count else { return nil }
            let start = i
            while i < bytes.count && bytes[i] != 0 { i += 1 }
            let text = String(decoding: bytes[start..<i], as: UTF8.self)
            i += 1
            return text
        }
        var info = Info(path: string() ?? "", arguments: [], environment: [:])
        while i < bytes.count && bytes[i] == 0 { i += 1 }
        for _ in 0..<max(argc, 0) {
            guard let argument = string() else { return info }
            info.arguments.append(argument)
        }
        while let line = string(), !line.isEmpty {
            if let eq = line.firstIndex(of: "=") {
                info.environment[String(line[..<eq])] = String(line[line.index(after: eq)...])
            }
        }
        return info
    }

    // Steam's gameprocess_log.txt: "AppID 1245620 adding PID 4321 as a tracked process ..."
    // and "AppID 1245620 no longer tracking PID 4321, exit code 0". The PIDs still tracked, by app.
    static func tracked(inLog text: String) -> [Int: [pid_t]] {
        var out: [Int: [pid_t]] = [:]
        for line in text.split(separator: "\n") {
            guard let range = line.range(of: "AppID ") else { continue }
            let rest = line[range.upperBound...]
            let digits = rest.prefix { $0.isNumber }
            guard let appID = Int(digits), let pidRange = rest.range(of: "PID ") else { continue }
            guard let pid = pid_t(rest[pidRange.upperBound...].prefix { $0.isNumber }) else { continue }
            if rest.contains("adding PID") {
                out[appID, default: []].append(pid)
            } else if rest.contains("no longer tracking PID") {
                out[appID]?.removeAll { $0 == pid }
                if out[appID]?.isEmpty == true { out[appID] = nil }
            }
        }
        return out
    }
}
