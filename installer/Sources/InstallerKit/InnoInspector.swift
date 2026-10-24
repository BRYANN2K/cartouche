// Reads an Inno Setup installer with innoextract, which parses the setup data without executing anything.

import Foundation

// One file the installer script writes, with the uncompressed size the script promises.
// A language-specific file lands only when that language is chosen at install.
public struct InnoFileEntry: Sendable, Equatable {
    public let path: String
    public let bytes: Int64
    public var languageSpecific: Bool
    public init(path: String, bytes: Int64, languageSpecific: Bool = false) {
        self.path = path; self.bytes = bytes; self.languageSpecific = languageSpecific
    }
}

public struct InnoReport: Sendable, Equatable {
    public var title: String?
    public var version: String?
    public var languages: [String] = []
    public var passworded = false
    public var files: [String] = []

    // FreeArc-style unpacking: ISDone/unarc plus external decompressors. CPU and RAM heavy.
    public var heavyDecompression: Bool {
        files.contains { name in
            let n = name.lowercased()
            return n.hasSuffix("isdone.dll") || n.hasSuffix("unarc.dll") || n.contains("/cls-") || n.hasSuffix("xtool.exe")
        }
    }
    public var decompressors: [String] {
        let known = ["unarc", "isdone", "facompress", "cls-lollypop", "cls-srep", "cls-magic2", "cls-mpzz", "razor", "xtool", "precomp", "liblz4", "oo2core"]
        return known.filter { k in files.contains { $0.lowercased().contains(k) } }
    }
    public var customInterface: Bool { files.contains { $0.lowercased().hasSuffix("botva2.dll") } }
    // Inno Download Plugin: the installer may fetch files while it runs.
    public var downloadsDuringInstall: Bool { files.contains { $0.lowercased().hasSuffix("idp.dll") } }
    public var redistributables: [String] {
        files.filter { $0.lowercased().contains("_redist/") && $0.lowercased().hasSuffix(".exe") && !$0.lowercased().contains("quicksfv") }
    }
}

public enum InnoInspector {

    public enum Failure: Error, Equatable {
        case toolMissing
        case notInno(String)
        // The file is Inno but its setup data version is above the tool's range.
        case newerThanSupported(String)
    }

    // Only innoextract runs, with the setup as a file to read.
    public static func inspect(
        _ setup: URL, tool: String? = Innoextract.path(), runner: any ToolRunning = ProcessToolRunner()
    ) throws -> InnoReport {
        guard let tool else { throw Failure.toolMissing }
        let path = setup.path(percentEncoded: false)
        let info = try runner.run(tool, ["--info", path])
        if info.contains("Not a supported Inno Setup installer") {
            // Before giving up, innoextract warns when it reads an Inno header
            // whose data version it does not know: report that cleanly.
            if let found = unexpectedVersion(in: info), isNewer(found, tool: tool, runner: runner) {
                throw Failure.newerThanSupported(found)
            }
            throw Failure.notInno(info)
        }
        let list = try runner.run(tool, ["--list", "--silent", path])
        return parse(info: info, list: list)
    }

    // The script's file list with each file's promised size: `--list-sizes --silent` prints
    // `<bytes> <name>` lines, the names in the same section-prefixed shape --list gives.
    public static func listSizes(
        _ setup: URL, tool: String? = Innoextract.path(), runner: any ToolRunning = ProcessToolRunner()
    ) throws -> [InnoFileEntry] {
        guard let tool else { throw Failure.toolMissing }
        let out = try runner.run(tool, ["--list-sizes", "--silent", setup.path(percentEncoded: false)])
        if out.contains("Not a supported Inno Setup installer") { throw Failure.notInno(out) }
        return parseSizes(out)
    }

    // `--language-only` lists only the files tied to a language, in --list's path shape. innoextract
    // prints nothing about components or tasks, so those stay unmarked. A failed run marks nothing.
    public static func markingLanguageFiles(
        _ entries: [InnoFileEntry], setup: URL, tool: String? = Innoextract.path(),
        runner: any ToolRunning = ProcessToolRunner()
    ) -> [InnoFileEntry] {
        guard let tool, !entries.isEmpty,
              let out = try? runner.run(tool, ["--language-only", "--list-sizes", "--silent", setup.path(percentEncoded: false)]),
              !out.contains("Not a supported Inno Setup installer") else { return entries }
        let tied = Set(parseSizes(out).map { $0.path.lowercased() })
        guard !tied.isEmpty else { return entries }
        return entries.map { entry in
            var marked = entry
            marked.languageSpecific = tied.contains(entry.path.lowercased())
            return marked
        }
    }

    public static func parseSizes(_ list: String) -> [InnoFileEntry] {
        list.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let match = try? /^(\d+)\s+(.+)$/.wholeMatch(in: line),
                  let bytes = Int64(match.1) else { return nil }
            let path = String(match.2).trimmingCharacters(in: .whitespaces)
            return path.isEmpty ? nil : InnoFileEntry(path: path, bytes: bytes)
        }
    }

    // "Unexpected setup data version: 6.5.0 (unicode)" — the Inno header was
    // recognised but the data version is not in the tool's known list.
    static func unexpectedVersion(in output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline) {
            if let m = try? /Unexpected setup data version:\s*([0-9][0-9.]*)/.firstMatch(in: line) {
                return String(m.1)
            }
        }
        return nil
    }

    // The tool's own --version reports its ceiling ("…Inno Setup 1.2.10 to 6.3.3"),
    // so the check holds for the bundled copy and for an older Homebrew fallback.
    static func isNewer(_ version: String, tool: String, runner: any ToolRunning) -> Bool {
        guard let ceiling = supportedCeiling(tool: tool, runner: runner) else { return false }
        var parts = version.split(separator: ".").map { Int($0) ?? 0 }
        parts += [Int](repeating: 0, count: max(0, ceiling.count - parts.count))
        for (a, b) in zip(parts, ceiling) where a != b { return a > b }
        return parts.count > ceiling.count
    }

    static func supportedCeiling(tool: String, runner: any ToolRunning) -> [Int]? {
        guard let out = try? runner.run(tool, ["--version"]),
              let m = try? /Inno Setup [0-9.]+ to ([0-9.]+)/.firstMatch(in: out) else { return nil }
        return m.1.split(separator: ".").compactMap { Int($0) }
    }

    public static func parse(info: String, list: String) -> InnoReport {
        var report = InnoReport()
        var inLanguages = false
        for line in info.split(whereSeparator: \.isNewline).map(String.init) {
            // Inspecting "CarX Street" - setup data version 5.5.0.1 (unicode)
            if let m = try? /Inspecting "(.+)" - setup data version ([0-9.]+)/.firstMatch(in: line) {
                report.title = String(m.1); report.version = String(m.2)
            }
            if line.hasPrefix("Languages:") { inLanguages = true; continue }
            if inLanguages {
                if let m = try? /^\s*-\s*([^:]+):/.firstMatch(in: line) { report.languages.append(String(m.1)) } else { inLanguages = false }
            }
            if line.contains("Setup is passworded") || line.contains("is password protected") { report.passworded = true }
        }
        report.files = list.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return report
    }
}
