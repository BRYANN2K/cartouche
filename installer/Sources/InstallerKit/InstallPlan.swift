// Turns an analysis into what the app shows and runs: the game name to look up,
// the space needed, the Inno command line, and the exe to launch afterwards.

import Foundation

public enum GameName {

    // "CarX Street [Offline Installer]" → "CarX Street"
    // "The Witcher 3 Wild Hunt GOTY (Offline Installer) v4.04 + 2 DLCs" → "The Witcher 3 Wild Hunt GOTY"
    public static func clean(_ folder: String) -> String {
        var s = folder.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: ".", with: " ")
        s = s.replacing(/\[[^\]]*\]|\([^)]*\)|\{[^}]*\}/, with: "")
        s = s.replacing(/(?i)\s[-–]?\s*(v|build|update|b)\s?\d[\w.\-]*.*$/, with: "")
        s = s.replacing(/(?i)\s\+\s.*$/, with: "")
        s = s.replacing(/(?i)\b(multi\d*|setup|installer|gog|steam|rip|deluxe edition)\b/, with: "")
        return s.split(whereSeparator: \.isWhitespace).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "-–")))
    }
}

public struct SpaceEstimate: Sendable, Equatable {
    public let installed: Int64
    public let temporary: Int64
    public var total: Int64 { installed + temporary }

    // The installed size is not in the installer data (records.inf only holds
    // progress weights), so it is estimated from the compressed parts. Heavy
    // decompressors write temp files inside the game folder (TempPath={app}).
    public static func from(compressed: Int64, heavy: Bool) -> SpaceEstimate {
        let ratio = heavy ? 2.5 : 1.6
        let installed = Int64(Double(compressed) * ratio)
        return SpaceEstimate(installed: installed, temporary: heavy ? max(installed / 10, 2 << 30) : installed / 20)
    }
}

public struct InnoCommand: Sendable, Equatable {
    public enum Mode: String, Sendable { case guided, automatic }

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
        public let path: String
        public let reason: String
        public let score: Int
    }

    nonisolated(unsafe) private static let noise = /(?i)(unins\d*|setup|crash|report|redist|vcredist|dxsetup|dxwebsetup|directx|dotnet|ue4prereq|easyanticheat|quicksfv|helper|launcherpatcher|7z)/

    // shortcuts: targets of .lnk files the installer created, most trusted.
    // uninstallIcon: DisplayIcon from the Uninstall registry key.
    public static func rank(exes: [(path: String, size: Int64)], shortcuts: [String] = [], uninstallIcon: String? = nil) -> [Candidate] {
        let biggest = exes.map(\.size).max() ?? 1
        return exes.compactMap { exe in
            let name = (exe.path as NSString).lastPathComponent
            if (try? noise.firstMatch(in: name)) != nil { return nil }
            if shortcuts.contains(where: { $0.caseInsensitiveCompare(exe.path) == .orderedSame }) {
                return Candidate(path: exe.path, reason: "From the Start Menu shortcut", score: 100)
            }
            if let icon = uninstallIcon, icon.caseInsensitiveCompare(exe.path) == .orderedSame {
                return Candidate(path: exe.path, reason: "Registered by the installer", score: 80)
            }
            let depth = exe.path.split(separator: "/").count
            let launcher = name.lowercased().contains("launcher")
            let score = Int(40 * Double(exe.size) / Double(biggest)) - depth * 3 - (launcher ? 15 : 0)
            return Candidate(path: exe.path, reason: launcher ? "Launcher from the publisher" : "Largest program in the folder", score: score)
        }
        .sorted { $0.score > $1.score }
    }
}
