// Reads an Inno Setup installer with innoextract, which parses the setup data
// without executing anything.

import Foundation

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
    // Skinned installer window (botva2), often with music.
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
    }

    public static func innoextractPath() -> String? { Innoextract.path() }

    // Only innoextract runs, with the setup as a file to read.
    public static func inspect(
        _ setup: URL, tool: String? = Innoextract.path(), runner: any ToolRunning = ProcessToolRunner()
    ) throws -> InnoReport {
        guard let tool else { throw Failure.toolMissing }
        let path = setup.path(percentEncoded: false)
        let info = try runner.run(tool, ["--info", path])
        if info.contains("Not a supported Inno Setup installer") { throw Failure.notInno(info) }
        let list = try runner.run(tool, ["--list", "--silent", path])
        return parse(info: info, list: list)
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
