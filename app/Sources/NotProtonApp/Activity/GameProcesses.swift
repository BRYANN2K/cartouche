// Steam logs tracked game PIDs to logs/gameprocess_log.txt; macOS no longer shows another process's environment, so SteamGameId is a last resort.

import CoreGraphics
import Darwin
import Foundation
import InstallerKit

// Whether a game still shows a window: Wine's Mac driver gives each Windows window a
// normal-level window owned by the process that runs it, hidden or on another Space too.
enum GameWindows {
    static func any(owners: Set<pid_t>) -> Bool {
        guard !owners.isEmpty,
              let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]]
        else { return false }
        return windows.contains { window in
            guard let owner = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  owners.contains(owner) else { return false }
            return (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0
        }
    }
}

struct GameProcesses: Sendable {

    var grace: Duration = .seconds(5)
    var candidates: @Sendable () -> [pid_t] = GameProcesses.allProcesses

    struct Info: Equatable, Sendable {
        var path: String
        var arguments: [String]
        var environment: [String: String]
    }

    // The same folder match with no store app ID: an installer game carries no
    // SteamGameId, so its processes are the ones its folder's exe and argv reach.
    func pids(installFolder: URL) -> [pid_t] { pids(appID: 0, installFolder: installFolder) }

    // tracked PIDs count only after trusted clears them: a crashed Steam leaves "adding PID" entries forever, and a reused PID must never be taken for the game.
    func pids(appID: Int, tracked: [pid_t: Date] = [:], installFolder: URL? = nil, winePrefix: URL? = nil) -> [pid_t] {
        let me = getpid()
        let all = candidates().filter { $0 > 1 && $0 != me }
        let folder = installFolder.map { Self.folderPrefix($0) }
        var found = Set(tracked.filter { pid, added in Self.trusted(pid, added: added, folder: folder, winePrefix: winePrefix) }.keys)
        let wanted = String(appID)
        for pid in all where !found.contains(pid) {
            guard let info = Self.info(of: pid) else { continue }
            if info.environment["SteamGameId"] == wanted || info.environment["SteamAppId"] == wanted {
                found.insert(pid)
            } else if let folder, info.path.hasPrefix(folder) || info.arguments.contains(where: { $0.hasPrefix(folder) }) {
                found.insert(pid)
            }
        }
        // Steam's own client is never the game, and its children are not the game's
        found = found.filter { !Self.isSteamClient($0) }
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
    func quit(appID: Int, tracked: [pid_t: Date] = [:], installFolder: URL? = nil, winePrefix: URL? = nil) -> Int {
        let (signalled, killed) = terminate(pids(appID: appID, tracked: tracked, installFolder: installFolder, winePrefix: winePrefix))
        if signalled > 0 { AppLog.note("quit game \(appID): \(signalled) processes, \(killed) killed") }
        return signalled
    }

    // Never signalled: Steam's own client, and whatever listens on this port.
    var sparedPort = 8765
    var spares: @Sendable (pid_t, Int) -> Bool = GameProcesses.isSpared

    // SIGTERM, then SIGKILL for what still lives after the grace; spared processes are left alone.
    @discardableResult
    func terminate(_ pids: [pid_t]) -> (signalled: Int, killed: Int) {
        let me = getpid()
        let targets = pids.filter { $0 > 1 && $0 != me && !spares($0, sparedPort) }
        guard !targets.isEmpty else { return (0, 0) }
        for pid in targets { kill(pid, SIGTERM) }
        let deadline = ContinuousClock.now + grace
        var alive = targets
        while !alive.isEmpty && ContinuousClock.now < deadline {
            usleep(100_000)
            alive = alive.filter(Self.isAlive)
        }
        for pid in alive { kill(pid, SIGKILL) }
        return (targets.count, alive.count)
    }

    static func isSpared(_ pid: pid_t, port: Int) -> Bool {
        isSteamClient(pid) || listens(pid, port: port)
    }

    static let steamClientNames: Set<String> = ["steam_osx", "steamwebhelper", "Steam Helper"]

    // Steam itself: its client by name, or any process running from inside Steam's app bundles.
    static func isSteamClient(_ pid: pid_t) -> Bool {
        if steamClientNames.contains(PrefixStore.comm(of: pid)) { return true }
        guard let path = info(of: pid)?.path else { return false }
        return steamRoots.contains { path.hasPrefix($0) }
    }

    // A TCP socket of the process listening on the port, read through libproc.
    static func listens(_ pid: pid_t, port: Int) -> Bool {
        let stride = MemoryLayout<proc_fdinfo>.stride
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else { return false }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(needed) / stride + 16)
        let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * stride))
        guard filled > 0 else { return false }
        for fd in fds.prefix(Int(filled) / stride) where Int(fd.proc_fdtype) == Int(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size,
                  Int(info.psi.soi_kind) == Int(SOCKINFO_TCP) else { continue }
            let tcp = info.psi.soi_proto.pri_tcp
            let local = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport)))
            if Int(tcp.tcpsi_state) == Int(TSI_S_LISTEN) && local == port { return true }
        }
        return false
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
    static func trusted(_ pid: pid_t, added: Date, folder: String?, winePrefix: URL? = nil) -> Bool {
        guard isAlive(pid), let start = start(of: pid),
              start >= added.addingTimeInterval(-1) else { return false }
        var current = pid
        for _ in 0..<16 {
            guard let info = info(of: current) else { return false }
            if isGamePath(info.path, args: info.arguments, folder: folder) { return true }
            if let folder, let winePrefix,
               info.arguments.compactMap({ windowsPath($0, prefix: winePrefix) }).contains(where: { $0.hasPrefix(folder) }) {
                return true
            }
            guard let parent = parent(of: current), parent > 1, parent != current else { return false }
            current = parent
        }
        return false
    }

    static func windowsPath(_ argument: String, prefix: URL) -> String? {
        let value = argument.replacingOccurrences(of: "\\", with: "/")
        let chars = Array(value)
        guard chars.count > 3, chars[0].isASCII, chars[0].isLetter, chars[1] == ":", chars[2] == "/" else { return nil }
        let drive = prefix.appending(path: "dosdevices/\(String(chars[0]).lowercased()):")
        guard FileManager.default.fileExists(atPath: drive.path) else { return nil }
        return drive.resolvingSymlinksInPath().appending(path: String(chars.dropFirst(3)))
            .standardizedFileURL.path(percentEncoded: false)
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

    // One sysctl for the whole table; p_comm is the exec'd file name, capped at 16 bytes.
    // The table can grow between sizing and reading: the buffer gets slack, then a retry
    static func processExists(named names: Set<String>) -> Bool {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return false }
        for _ in 0..<3 {
            var table = [kinfo_proc](repeating: kinfo_proc(),
                                     count: size / MemoryLayout<kinfo_proc>.stride + 64)
            var got = table.count * MemoryLayout<kinfo_proc>.stride
            if sysctl(&mib, 4, &table, &got, nil, 0) == 0 {
                for entry in table.prefix(got / MemoryLayout<kinfo_proc>.stride) {
                    var comm = entry.kp_proc.p_comm
                    let name = withUnsafeBytes(of: &comm) {
                        String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
                    }
                    if names.contains(name) { return true }
                }
                return false
            }
            guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return false }
        }
        return false
    }

    // The same name SteamBundle.isRunning hands to pgrep
    static func steamStartedAt() -> Date? {
        allProcesses().compactMap { pid -> Date? in
            var buffer = [CChar](repeating: 0, count: 64)
            guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0,
                  String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) == "steam_osx" else { return nil }
            return start(of: pid)
        }.min()
    }

    static func steamIsRunning() -> Bool {
        processExists(named: ["steam_osx"])
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

// Stop for a Steam game run through Wine: only the wineserver and clients of its own compatdata
// prefix. wineserver -k ends them when the tool that last ran the prefix is still set up; otherwise
// each gets SIGTERM, then SIGKILL. -k is skipped while a spared process is a client, as it would end it too.
struct SteamGameStop: Sendable {

    enum Outcome: Equatable, Sendable {
        case noPrefix
        // lsof gave no clear answer, so nothing was signalled
        case unknown
        case notRunning
        case stopped(Int)
    }

    var files = SteamLocalFiles()
    var processes = GameProcesses()
    var serverRoot = PrefixStore.serverRoot
    var clients: @Sendable (WinePrefix, URL) -> [pid_t]? = { SteamGameStop.clients(of: $0, serverRoot: $1) }
    var server: @Sendable (WinePrefix) -> URL? = { try? PrefixTools.wine(for: $0, step: "").server }
    var killServer: @Sendable (URL, WinePrefix) -> Bool = { server, prefix in
        let result = try? Shell.run(server.path(percentEncoded: false), ["-k"],
                                    environment: ["WINEPREFIX": prefix.pfx.path(percentEncoded: false)])
        return result?.succeeded == true
    }

    func stop(appID: Int) -> Outcome {
        guard let prefix = files.compatPrefix(appID: appID) else { return .noPrefix }
        guard let found = clients(prefix, serverRoot) else { return .unknown }
        let me = getpid()
        let targets = found.filter { $0 > 1 && $0 != me }
        guard !targets.isEmpty else { return .notRunning }
        let spared = targets.filter { processes.spares($0, processes.sparedPort) }
        if spared.isEmpty, let server = server(prefix), killServer(server, prefix) {
            AppLog.note("stop steam game \(appID): wineserver -k on its prefix, \(targets.count) processes")
            return .stopped(targets.count)
        }
        let (signalled, killed) = processes.terminate(targets)
        AppLog.note("stop steam game \(appID): \(signalled) processes, \(killed) killed, \(spared.count) spared")
        return .stopped(signalled)
    }

    // The prefix's wineserver, what lsof finds in its server directory and the server's children; nil when lsof is unclear.
    static func clients(of prefix: WinePrefix, serverRoot: URL, lsof: String = "/usr/sbin/lsof") -> [pid_t]? {
        guard let dir = PrefixStore.serverDirectory(of: prefix, root: serverRoot),
              FileManager.default.fileExists(atPath: dir.path(percentEncoded: false)) else { return [] }
        guard let result = try? Shell.run(lsof, ["-t", "+D", dir.path(percentEncoded: false)], drainTimeout: .seconds(2)),
              !result.outputLost, result.stderr.isEmpty else { return nil }
        var pids = Set(result.stdout.split(whereSeparator: \.isNewline)
            .compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) })
        for pid in pids where PrefixStore.comm(of: pid).lowercased().hasPrefix("wineserver") {
            pids.formUnion(ProcessGroup(root: pid, prefix: nil).entries(environments: false).map(\.pid))
        }
        return pids.sorted()
    }
}

extension SteamLocalFiles {
    // compatdata/<appID>/pfx in the library that holds the game, else in any library that has one
    func compatPrefix(appID: Int, name: String? = nil) -> WinePrefix? {
        var roots = libraries()
        if let folder = installFolder(appID: appID) {
            roots.insert(folder.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent(), at: 0)
        }
        for root in roots {
            let prefix = WinePrefix(appID: String(appID), name: name, library: SteamLibrary(root: root), lastUsed: nil)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: prefix.pfx.path(percentEncoded: false), isDirectory: &isDirectory),
               isDirectory.boolValue { return prefix }
        }
        return nil
    }
}
