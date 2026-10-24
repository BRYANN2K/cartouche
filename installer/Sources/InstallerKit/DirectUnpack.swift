// Direct unpacking for installers with external unpackers: when the Inno file list shows the
// FreeArc/CLS pattern (unarc.dll, CLS helpers, arc.ini) and the .bin parts next to setup.exe all
// carry the FreeArc signature, the parts are extracted by Cartouche's own Win32 driver through the
// installer's unarc.dll — setup.tmp and ISDone never run. Anything that does not match the pattern
// keeps the normal installer path.

import Foundation

public struct DirectUnpackPlan: Sendable, Equatable {
    // The .bin parts, in the order the parts list gives them (fg-01.bin, fg-02.bin, …).
    public var parts: [URL]
    // tmp helper base names the installer ships, sorted; diagnostics only.
    public var helpers: [String]
    // The module the driver loads, e.g. "unarc.dll".
    public var unarcModule: String
    // The FreeArc/decompressor config next to the helpers, e.g. "arc.ini".
    public var arcConfig: String
    // The CLS settings file when the installer ships one, e.g. "CLS.ini".
    public var clsConfig: String?
    // An .md5 manifest inside the app section, relative to it, e.g. "_Redist/fitgirl.md5".
    public var manifestPath: String?

    public init(parts: [URL], helpers: [String], unarcModule: String, arcConfig: String,
                clsConfig: String?, manifestPath: String?) {
        self.parts = parts; self.helpers = helpers; self.unarcModule = unarcModule
        self.arcConfig = arcConfig; self.clsConfig = clsConfig; self.manifestPath = manifestPath
    }
}

public enum DirectUnpack {

    // The bundled driver staged into drive_c/U and run as C:\U\unarc-driver.exe.
    public static let driverName = "unarc-driver.exe"
    public static let helperUnixDir = "drive_c/U"
    public static let helperDir = #"C:\U"#

    // innoextract unpacks an installer by sections; "tmp" is the helper tree setup would get in
    // {tmp}, "app" is what it would put in {app}.
    public static let helperSection = "tmp"
    public static let appSection = "app"

    // The FreeArc/CLS signature: the unpacker, its config, at least one CLS helper, and a folder
    // where every .bin is a numbered FreeArc part. An Inno-native .bin or an unrelated archive in
    // the folder means the setup path stays in charge.
    public static func plan(inno: InnoReport?, scan: PartScan) -> DirectUnpackPlan? {
        guard let inno, !inno.passworded else { return nil }
        let listed = inno.files.map { $0.replacingOccurrences(of: "\\", with: "/") }
        let tmp = listed.filter { $0.lowercased().hasPrefix(helperSection + "/") }
        let names = Set(tmp.map { ($0 as NSString).lastPathComponent.lowercased() })
        guard let unarc = tmp.first(where: { ($0 as NSString).lastPathComponent.lowercased() == "unarc.dll" }),
              let arc = tmp.first(where: { ($0 as NSString).lastPathComponent.lowercased() == "arc.ini" }),
              names.contains(where: { $0.hasPrefix("cls-") || $0.hasPrefix("cls_") })
        else { return nil }
        let clsConfig = tmp.first { ($0 as NSString).lastPathComponent.lowercased() == "cls.ini" }
            .map { ($0 as NSString).lastPathComponent }

        let folder = scan.folder
        let bins = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? [])
            .filter { $0.lowercased().hasSuffix(".bin") }
        guard !scan.parts.isEmpty,
              Set(bins).isSubset(of: Set(scan.parts.map { $0.url.lastPathComponent })),
              scan.parts.allSatisfy({ ExternalUnpacker.isFreeArc($0.url) })
        else { return nil }

        let manifest = listed
            .filter { $0.lowercased().hasPrefix(appSection + "/") && $0.lowercased().hasSuffix(".md5") }
            .sorted().first
            .map { String($0.dropFirst(appSection.count + 1)) }
        return DirectUnpackPlan(
            parts: scan.parts.map(\.url), helpers: tmp.map { ($0 as NSString).lastPathComponent }.sorted(),
            unarcModule: (unarc as NSString).lastPathComponent,
            arcConfig: (arc as NSString).lastPathComponent,
            clsConfig: clsConfig, manifestPath: manifest
        )
    }

    // The arguments FreeArcExtract gets, minus the leading "x": the part is appended by the caller.
    public static func arguments(installDir: String, tempDir: String, config: String) -> [String] {
        ["x", "-o+", "-dp\(installDir)", "-w\(tempDir)", "-cfg\(config)"]
    }

    // CLS.ini's TempPath placeholders carry "{app}", which Inno would have substituted before the
    // helpers read the file; byte-exact so the file's encoding and other keys are untouched.
    public static func patchedTempConfig(_ data: Data, tempDir: String) -> Data {
        let marker = Data("{app}".utf8)
        let replacement = Data(tempDir.utf8)
        var out = data
        while let range = out.range(of: marker) {
            out.replaceSubrange(range, with: replacement)
        }
        return out
    }

    // Writes CLS.ini with the temp dir substituted and, when the run asks for them, the memory and
    // thread limits CLSConfig already knows how to apply. Returns false when there is no CLS.ini.
    @discardableResult
    public static func patchConfig(at ini: URL, tempDir: String, memoryPercent: Int?, threads: Int?) throws -> Bool {
        guard var data = try? Data(contentsOf: ini) else { return false }
        data = patchedTempConfig(data, tempDir: tempDir)
        if memoryPercent != nil || threads != nil {
            let patched = CLSConfig.patched(String(decoding: data, as: UTF8.self), memoryPercent: memoryPercent, threads: threads)
            data = Data(patched.utf8)
        }
        try data.write(to: ini, options: .atomic)
        return true
    }

    // The driver prints unarc's "result N" and its callback's "error …" lines; the code table is
    // the same one InstallLog applies to the error lines of the normal path.
    public static func diagnose(status: Int32, log: String?) -> InstallDiagnosis {
        let lines = (log ?? "").split(whereSeparator: \.isNewline)
            .map { InstallLog.stripStamp(String($0)) }.filter { !$0.isEmpty }
        func first<Output>(_ pattern: Regex<Output>) -> String? {
            lines.first { (try? pattern.firstMatch(in: $0)) != nil }
        }

        if let line = first(/(?i)cannot load|exports no FreeArcExtract|CreateFileMapping|MapViewOfFile/) {
            return InstallDiagnosis(kind: .setupFailed, causes: [.runner], fixes: [.otherRunner],
                                    exitCode: status, detail: line, explanation: .diedBeforeWizard)
        }
        if let line = first(/(?i)not enough (free )?(disk )?space|disk is full|no space left/) {
            return InstallDiagnosis(kind: .diskSpace, causes: [.diskSpace], fixes: [], exitCode: status, detail: line)
        }
        if let line = first(/(?i)(source|data) file .*does not exist|file .* is missing|not found any file|cannot (find|open)/) {
            return InstallDiagnosis(kind: .missingPart, causes: [.missingPart], fixes: [],
                                    exitCode: status, detail: line, explanation: .missingPart)
        }
        let code = lines.reversed().compactMap { line -> Int32? in
            guard let match = try? /^result\s+(-?\d+)\s*$/.wholeMatch(in: line) else { return nil }
            return Int32(match.1)
        }.first ?? status
        let detail = lines.last { $0.hasPrefix("error") } ?? lines.last
        switch code {
        case -2, -11, -12:
            return InstallDiagnosis(kind: .decompression, causes: [.memory, .path, .damagedFile],
                                    fixes: [.lessMemory, .fewerThreads, .verifyFiles, .shortPath],
                                    exitCode: status, detail: detail, explanation: .decompressorMemory)
        case -1, -3, -14:
            return InstallDiagnosis(kind: .decompression, causes: [.damagedFile, .memory, .path],
                                    fixes: [.verifyFiles, .lessMemory, .fewerThreads, .shortPath],
                                    exitCode: status, detail: detail, explanation: .decompressorData)
        case -6, -7:
            return InstallDiagnosis(kind: .decompression, causes: [.path, .diskSpace, .damagedFile],
                                    fixes: [.shortPath, .verifyFiles],
                                    exitCode: status, detail: detail, explanation: .decompressorIO)
        default:
            return InstallDiagnosis(kind: .decompression, causes: [.memory, .path, .damagedFile],
                                    fixes: [.verifyFiles, .fewerThreads, .lessMemory, .shortPath],
                                    exitCode: status, detail: detail, explanation: .helperFailed)
        }
    }
}
