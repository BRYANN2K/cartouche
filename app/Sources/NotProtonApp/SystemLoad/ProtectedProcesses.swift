import Darwin
import Foundation

enum Protection: Equatable, Sendable {
    case system, cartouche, game, launcher, user

    var reason: String {
        switch self {
        case .system: String(localized: "macOS needs this process.")
        case .cartouche: String(localized: "This is Cartouche.")
        case .game: String(localized: "This runs your game or Wine.")
        case .launcher: String(localized: "This is a game launcher.")
        case .user: String(localized: "You protected this app in Settings > Resources.")
        }
    }
}

// What the Resources view never quits or pauses. The fixed part cannot be changed; the
// user adds apps by name or bundle ID in Settings.
struct ProtectedProcesses: Sendable {

    static let defaultUserList: [String] = []
    // What 0.2.0-beta1 shipped as the default list, by mistake. A stored list still equal to
    // it means the user never chose: the update clears it.
    static let betaUserList = ["Orca", "Promethee"]

    static let systemNames: Set<String> = [
        "kernel_task", "launchd", "WindowServer", "Finder", "Dock", "loginwindow", "SystemUIServer",
        "ControlCenter", "NotificationCenter", "coreaudiod", "mds", "mds_stores",
    ]
    static let systemBundles: Set<String> = ["com.apple.finder", "com.apple.dock", "com.apple.loginwindow"]
    // Apple's apps under /System/Applications stay quittable; Safari lives in a cryptex there too.
    static let systemRoots = ["/System/", "/usr/", "/bin/", "/sbin/", "/Library/Apple/", "/private/var/"]
    static let userAppRoots = ["/System/Applications/", "/System/Volumes/Preboot/Cryptexes/App/"]
    static let gameNameMarks = ["wine", "wineserver"]
    static let launcherNameMarks = ["steam_osx", "steamwebhelper", "Steam Helper"]

    var me: pid_t = getpid()
    var myUID: uid_t = getuid()
    // Cartouche's Application Support: runners, Steam, RetroArch, the game prefixes
    var gameRoots: [String] = [GameProcesses.folderPrefix(SupportPaths.support)]
    // The Steam client itself, wherever the user keeps it
    var launcherRoots: [String] = GameProcesses.steamRoots
    var userList: [String] = ProtectedProcesses.defaultUserList

    // Every PID of the sample that is protected, and why. A process started by a protected
    // one shares its protection.
    func classify(_ processes: [pid_t: ProcessReading], apps: [pid_t: RunningAppInfo],
                  unreadable: Set<pid_t> = []) -> [pid_t: Protection] {
        var direct: [pid_t: Protection] = [:]
        for (pid, process) in processes {
            if let protection = own(process, app: apps[pid]) { direct[pid] = protection }
        }
        var result: [pid_t: Protection] = [:]
        for pid in processes.keys {
            var current = pid
            for _ in 0..<32 {
                if let protection = direct[current] {
                    result[pid] = protection
                    break
                }
                guard let parent = processes[current]?.parent, parent > 1, parent != current else { break }
                current = parent
            }
        }
        // A GPU client libproc cannot read belongs to another user, WindowServer for one
        for pid in unreadable where processes[pid] == nil { result[pid] = .system }
        return result
    }

    func own(_ process: ProcessReading, app: RunningAppInfo?) -> Protection? {
        if process.pid == me { return .cartouche }
        if process.pid <= 1 || process.uid != myUID || Self.systemNames.contains(process.name) { return .system }
        if let bundle = app?.bundleID, Self.systemBundles.contains(bundle) { return .system }
        // Wine's processes often outlive their parent and end up under launchd
        if isGame(process) { return .game }
        // The Steam client is the game's launcher, never the game itself
        if isLauncher(process) { return .launcher }
        // Only what launchd started: a tool the user ran from a shell is theirs
        let path = process.path
        if process.parent <= 1, Self.systemRoots.contains(where: path.hasPrefix),
           !Self.userAppRoots.contains(where: path.hasPrefix) {
            return .system
        }
        if matchesUserList(process, app: app) { return .user }
        return nil
    }

    func isGame(_ process: ProcessReading) -> Bool {
        let name = process.name.lowercased()
        if name.hasSuffix(".exe") || Self.gameNameMarks.contains(where: { name.contains($0.lowercased()) }) { return true }
        let path = process.path
        return path.lowercased().hasSuffix(".exe") || gameRoots.contains(where: path.hasPrefix)
    }

    func isLauncher(_ process: ProcessReading) -> Bool {
        let name = process.name.lowercased()
        return Self.launcherNameMarks.contains(where: { name.contains($0.lowercased()) })
            || launcherRoots.contains(where: process.path.hasPrefix)
    }

    func matchesUserList(_ process: ProcessReading, app: RunningAppInfo?) -> Bool {
        let names = [process.name, app?.name, app?.bundleID, app?.bundlePath.map { URL(filePath: $0).deletingPathExtension().lastPathComponent }]
            .compactMap { $0?.lowercased() }
        let folders = process.path.lowercased().split(separator: "/").dropLast()
        for entry in userList.map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }) where !entry.isEmpty {
            if names.contains(entry) { return true }
            // A helper launchd started from the app's bundle, a sibling bundle like
            // "App Helper.app", or the app's Application Support folder
            if folders.contains(where: { $0 == entry || ($0.hasSuffix(".app") && ($0 == "\(entry).app" || $0.hasPrefix("\(entry) "))) }) {
                return true
            }
        }
        return false
    }

    // A row can be acted on only when none of its processes is protected.
    static func protection(of row: ResourceUsage, in map: [pid_t: Protection]) -> Protection? {
        let found = row.pids.compactMap { map[$0] }
        return [Protection.system, .cartouche, .game, .launcher, .user].first(where: found.contains)
    }
}
