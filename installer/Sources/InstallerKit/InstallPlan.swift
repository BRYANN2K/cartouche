
import Foundation

public enum GameName {

    // "CarX Street [Offline Installer]" → "CarX Street" "The Witcher 3 Wild Hunt GOTY (Offline Installer) v4.04 + 2 DLCs" → "The Witcher 3 Wild Hunt GOTY"
    public static func clean(_ folder: String) -> String {
        // "Stardew.Valley.1.6.8": a dotted version ends the name, before dots become spaces
        var s = folder.replacing(/[\s._-]v?\d+(\.\d+)+\b.*$/, with: "")
        // Site names dropped with the folder: "www.site.com" or a bare "SteamRIP.com"
        s = s.replacing(/(?i)\bwww\.[\w.\-]+\.[a-z]{2,}\b/, with: "")
        s = s.replacing(/(?i)\b\w+\.(com|net|org|io|ru|to|me|gg|biz|info|site)\b/, with: "")
        s = s.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: ".", with: " ").replacingOccurrences(of: "-", with: " ")
        s = s.replacing(/\[[^\]]*\]|\([^)]*\)|\{[^}]*\}/, with: "")
        s = s.replacing(/(?i)\s[-–]?\s*(v|build|update|b)\s?\d[\w.\-]*.*$/, with: "")
        s = s.replacing(/(?i)\s\+\s.*$/, with: "")
        s = s.replacing(/(?i)\b(multi\d*|setup|installer|gog|steam|steamrip|repack|portable|pre\s?installed|x64|x86|win64|win32|64bit|32bit|deluxe edition)\b/, with: "")
        return s.split(whereSeparator: \.isWhitespace).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "-–")))
    }

    // Still a folder name: clean() would drop real junk — a version tail, a site
    // name, bracketed tags — while "Half-Life" only loses a hyphen, which says nothing.
    public static func looksRaw(_ name: String) -> Bool {
        let cleaned = clean(name)
        guard cleaned != name else { return false }
        let squashed = { (s: String) in s.replacing(/[\s._\-]+/, with: " ").lowercased() }
        return squashed(cleaned) != squashed(name)
    }
}

public struct SpaceEstimate: Sendable, Equatable {
    public let installed: Int64
    public let temporary: Int64
    public var total: Int64 { installed + temporary }

    // The installed size is not in the installer data (records.inf only holds progress weights), so it is estimated
    // from the compressed parts. Heavy decompressors write temp files inside the game folder (TempPath={app}).
    public static func from(compressed: Int64, heavy: Bool) -> SpaceEstimate {
        let ratio = heavy ? 2.5 : 1.6
        let installed = Int64(Double(compressed) * ratio)
        return SpaceEstimate(installed: installed, temporary: heavy ? max(installed / 10, 2 << 30) : installed / 20)
    }
}

public struct InnoCommand: Sendable, Equatable {
    public enum Mode: String, Sendable, Codable { case guided, automatic }

    public let arguments: [String]

    public init(installDir: String, mode: Mode, language: String? = nil, log: String = #"C:\installer.log"#) {
        var args = ["/DIR=\(installDir)", "/NORESTART", "/LOG=\(log)"]
        if let language { args.append("/LANG=\(language)") }
        if mode == .automatic { args += ["/VERYSILENT", "/SUPPRESSMSGBOXES", "/NOCANCEL"] }
        arguments = args
    }
}

public enum ExeDetector {

    public struct Candidate: Sendable, Equatable {
        public enum Source: String, Sendable { case shortcut, gogInfo, registry, launcher, largest }

        public let path: String
        public let source: Source
        public let score: Int

        public var reason: String {
            switch source {
            case .shortcut: "From the Start Menu shortcut"
            case .gogInfo: "From the GOG game info"
            case .registry: "Registered by the installer"
            case .launcher: "Launcher from the publisher"
            case .largest: "Largest program in the folder"
            }
        }
    }

    nonisolated(unsafe) private static let noise = /(?i)(unins\d*|setup|crash|report|redist|vcredist|dxsetup|dxwebsetup|directx|dotnet|ue4prereq|easyanticheat|quicksfv|helper|launcherpatcher|7z)/

    // shortcuts: targets of .lnk files the installer created, most trusted. primary: the play task of a GOG info file. uninstallIcon: DisplayIcon from the Uninstall registry key.
    public static func rank(
        exes: [(path: String, size: Int64)], shortcuts: [String] = [], uninstallIcon: String? = nil, primary: String? = nil
    ) -> [Candidate] {
        let biggest = max(exes.map(\.size).max() ?? 1, 1)
        let same = { (a: String?, b: String) in a.map { $0.caseInsensitiveCompare(b) == .orderedSame } ?? false }
        return exes.compactMap { exe in
            let name = (exe.path as NSString).lastPathComponent
            if (try? noise.firstMatch(in: name)) != nil { return nil }
            if shortcuts.contains(where: { same($0, exe.path) }) { return Candidate(path: exe.path, source: .shortcut, score: 100) }
            if same(primary, exe.path) { return Candidate(path: exe.path, source: .gogInfo, score: 90) }
            if same(uninstallIcon, exe.path) { return Candidate(path: exe.path, source: .registry, score: 80) }
            let depth = exe.path.split(separator: "/").count
            let launcher = name.lowercased().contains("launcher")
            let score = Int(40 * Double(exe.size) / Double(biggest)) - depth * 3 - (launcher ? 15 : 0)
            return Candidate(path: exe.path, source: launcher ? .launcher : .largest, score: score)
        }
        .sorted { $0.score > $1.score }
    }
}
