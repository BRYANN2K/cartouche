// Steam logs tracked game PIDs to logs/gameprocess_log.txt; macOS no longer shows another process's environment, so SteamGameId is a last resort.

import Darwin
import Foundation

struct GameProcesses: Sendable {

    var grace: Duration = .seconds(5)
    var candidates: @Sendable () -> [pid_t] = GameProcesses.allProcesses

    struct Info: Equatable, Sendable {
        var path: String
        var arguments: [String]
        var environment: [String: String]
    }

    // tracked PIDs count only after trusted clears them: a crashed Steam leaves "adding PID" entries forever, and a reused PID must never be taken for the game.
    func pids(appID: Int, tracked: [pid_t: Date] = [:], installFolder: URL? = nil) -> [pid_t] {
        let me = getpid()
        let all = candidates().filter { $0 > 1 && $0 != me }
        let folder = installFolder.map { Self.folderPrefix($0) }
        var found = Set(tracked.filter { pid, added in Self.trusted(pid, added: added, folder: folder) }.keys)
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

    @discardableResult
    func quit(appID: Int, tracked: [pid_t: Date] = [:], installFolder: URL? = nil) -> Int {
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

    static func start(of pid: pid_t) -> Date? {
        var info = proc_bsdinfo()
        let size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        return size > 0 ? Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec)) : nil
    }

    // Counts only while the live process can still be the game: started when Steam logged it (macOS reuses PIDs), and it or an ancestor runs from the install folder or Steam.
    static func trusted(_ pid: pid_t, added: Date, folder: String?) -> Bool {
        guard isAlive(pid), let start = start(of: pid),
              start >= added.addingTimeInterval(-1) else { return false }
        var current = pid
        for _ in 0..<16 {
            guard let info = info(of: current) else { return false }
            if isGamePath(info.path, args: info.arguments, folder: folder) { return true }
            guard let parent = parent(of: current), parent > 1, parent != current else { return false }
            current = parent
        }
        return false
    }

    // The executable, an argument under the folder, or a process inside a Steam bundle.
    static func isGamePath(_ path: String, args: [String], folder: String?) -> Bool {
        if let folder, path.hasPrefix(folder) || args.contains(where: { $0.hasPrefix(folder) }) { return true }
        return steamRoots.contains { path.hasPrefix($0) }
    }

    // Steam.app and the real client inside Steam.AppBundle
    static var steamRoots: [String] {
        [SupportPaths.Steam.app.standardizedFileURL.path(percentEncoded: false) + "/",
         SupportPaths.Steam.innerApp.standardizedFileURL.path(percentEncoded: false) + "/"]
    }

    static func allProcesses() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard filled > 0 else { return [] }
        return Array(pids.prefix(Int(filled)))
    }

    // KERN_PROCARGS2 gives exe, args and, where macOS still shows it, environment; only the user's own processes answer.
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

    // Lines look like "AppID 1245620 adding PID 4321 as a tracked process"; a PID without a dated add counts as stale.
    static func tracked(inLog text: String) -> [Int: [pid_t: Date]] {
        var out: [Int: [pid_t: Date]] = [:]
        for line in text.split(separator: "\n") {
            guard let range = line.range(of: "AppID ") else { continue }
            let rest = line[range.upperBound...]
            let digits = rest.prefix { $0.isNumber }
            guard let appID = Int(digits), let pidRange = rest.range(of: "PID ") else { continue }
            guard let pid = pid_t(rest[pidRange.upperBound...].prefix { $0.isNumber }) else { continue }
            if rest.contains("adding PID") {
                guard let added = logStamp(line) else { continue }
                out[appID, default: [:]][pid] = added
            } else if rest.contains("no longer tracking PID") {
                out[appID]?[pid] = nil
                if out[appID]?.isEmpty == true { out[appID] = nil }
            }
        }
        return out
    }

    // The "[yyyy-MM-dd HH:mm:ss]" a Steam log line starts with, in local time
    static func logStamp(_ line: Substring) -> Date? {
        guard line.hasPrefix("["), line.count >= 21 else { return nil }
        let stamp = line.dropFirst().prefix(19)
        return logDate.date(from: String(stamp))
    }

    static let logDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}
