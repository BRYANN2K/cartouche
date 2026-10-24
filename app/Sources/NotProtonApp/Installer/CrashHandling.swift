//// What a crash does in a prefix Cartouche runs. Wine's default AeDebug starts `winedbg --auto`, which
//// opens the "Program Error" dialog and its Details window and holds the crashed process until both are
//// closed: the game stays running. With ShowCrashDialog off, winedbg --auto prints the backtrace to the
//// game's own output, detaches, and the process ends. Turning winedbg off (winedbg.exe=d) would lose the
//// backtrace, so it stays on.

import Foundation
import InstallerKit

enum CrashHandling {

    // Bumped when the registry below changes, so every prefix gets it again on its next launch.
    static let version = "1"
    static let markerName = "cartouche-crash"

    static let aeDebug = #"HKLM\Software\Microsoft\Windows NT\CurrentVersion\AeDebug"#
    static let wineDbg = #"HKCU\Software\Wine\WineDbg"#

    // Both registry views carry AeDebug: a 32-bit game reads its own.
    static let registryArguments: [[String]] = [
        ["reg", "add", wineDbg, "/v", "ShowCrashDialog", "/t", "REG_DWORD", "/d", "0", "/f"],
        ["reg", "add", aeDebug, "/v", "Debugger", "/t", "REG_SZ", "/d", "winedbg --auto %ld %ld", "/f"],
        ["reg", "add", aeDebug, "/v", "Auto", "/t", "REG_SZ", "/d", "1", "/f"],
        ["reg", "add", aeDebug, "/v", "Debugger", "/t", "REG_SZ", "/d", "winedbg --auto %ld %ld", "/f", "/reg:32"],
        ["reg", "add", aeDebug, "/v", "Auto", "/t", "REG_SZ", "/d", "1", "/f", "/reg:32"],
    ]

    // The launcher's share: once per prefix, before the game starts. A refused write never stops the game;
    // the marker stays unwritten and the next launch tries again.
    static var launcherLines: [String] {
        var lines = [#"crash_file="$WINEPREFIX/\#(markerName)""#,
                     #"if [ "$(cat "$crash_file" 2>/dev/null)" != '\#(version)' ]; then"#]
        let calls = registryArguments.map { arguments in
            #"  "$WINELOADER" "# + arguments.map(GameLauncher.quote).joined(separator: " ") + " >/dev/null 2>&1"
        }
        lines.append(calls.joined(separator: " &&\n") + " &&")
        lines.append(#"  printf '%s' '\#(version)' > "$crash_file""#)
        lines.append("fi")
        return lines
    }

    // A launcher written before crash handling gets the block right before it starts the game,
    // so an existing prefix is set on its next launch. Only a launcher that exports its loader.
    static func addLauncherLines(to folder: GameFolder) throws {
        let url = folder.launcher
        guard let text = try? String(contentsOf: url, encoding: .utf8), !text.contains(markerName),
              text.contains("\nexport WINELOADER=") else { return }
        var lines = text.components(separatedBy: "\n")
        guard let at = lines.firstIndex(where: { $0.hasPrefix("cd ") || $0.hasPrefix("exec ") }) else { return }
        lines.insert(contentsOf: launcherLines, at: at)
        try atomicReplace(url, with: Data(lines.joined(separator: "\n").utf8), step: String(localized: "Write the game's launcher"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path(percentEncoded: false))
    }

    // The same for a store game, which Cartouche starts itself. Call off the main actor, before launch.
    static func apply(wine: WineRunner, prefix: URL, environment: [String: String]) {
        let marker = prefix.appending(path: markerName)
        guard (try? String(contentsOf: marker, encoding: .utf8)) != version else { return }
        for arguments in registryArguments {
            do {
                try Shell.check(wine.loader.path(percentEncoded: false), arguments, environment: environment)
            } catch {
                AppLog.note("crash handling not set in \(prefix.path(percentEncoded: false)): \(error.localizedDescription)")
                return
            }
        }
        try? Data(version.utf8).write(to: marker, options: .atomic)
    }
}

//// A game's output goes to game.log beside its prefix, rewritten on every launch. When a run ends in
//// a crash, the log is copied to crash-<time>.log so the backtrace survives the next launch and can be shared.
enum CrashLog {

    static let gameLog = "game.log"
    static let namePrefix = "crash-"
    static let kept = 5

    // winedbg --auto's opening line, or Wine's own when no debugger could start.
    static func isCrash(_ text: String) -> Bool {
        text.contains("Unhandled exception") || text.contains("wine: Unhandled")
    }

    @discardableResult
    static func keep(_ log: URL, in folder: URL, now: Date = .now) -> URL? {
        guard let data = try? Data(contentsOf: log), isCrash(String(decoding: data, as: UTF8.self)) else { return nil }
        let stamp = PrefixStore.backupClock().string(from: now)
        var target = folder.appending(path: "\(namePrefix)\(stamp).log")
        var next = 2
        while FileManager.default.fileExists(atPath: target.path(percentEncoded: false)) {
            target = folder.appending(path: "\(namePrefix)\(stamp)-\(next).log")
            next += 1
        }
        guard (try? data.write(to: target, options: .atomic)) != nil else { return nil }
        for old in all(in: folder).dropFirst(kept) { try? FileManager.default.removeItem(at: old) }
        return target
    }

    // Newest first: the names sort by their time.
    static func all(in folder: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []
        return names.filter { $0.hasPrefix(namePrefix) && $0.hasSuffix(".log") }
            .sorted { $0.localizedStandardCompare($1) == .orderedDescending }
            .map { folder.appending(path: $0) }
    }

    static func latest(in folder: URL) -> URL? { all(in: folder).first }
}
