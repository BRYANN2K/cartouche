// Names the likely cause of a failed install from the exit code, the log Inno Setup writes with
// /LOG and Wine's own output, and says which retries may help.

import Foundation

public enum RetryFix: String, Sendable, CaseIterable, Codable {
    case verifyFiles, fewerThreads, lessMemory, shortPath, otherRunner
}

public struct InstallDiagnosis: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case success, cancelled, decompression, diskSpace, damagedFile, missingPart, setupFailed
    }

    public enum Cause: String, Sendable, Equatable {
        case memory, path, damagedFile, diskSpace, runner, missingPart
    }

    // A one-sentence reading of the raw line, mapped from the codes the helpers return.
    public enum Explanation: String, Sendable, Equatable {
        // -2, -11, -12: the decompressor could not get the memory it asked for.
        case decompressorMemory
        // -1, -3, -14: the archive data or its header is damaged.
        case decompressorData
        // -6, -7: the decompressor could not read the archive or write a file out.
        case decompressorIO
        // A part file the extractor needs is absent.
        case missingPart
        // The setup quit after unpacking its helpers, before its first page.
        case diedBeforeWizard
        // Another external-unpacker helper error.
        case helperFailed
    }

    public let kind: Kind
    public let causes: [Cause]
    public let fixes: [RetryFix]
    public let exitCode: Int32
    public let detail: String?
    public let explanation: Explanation?

    public init(kind: Kind, causes: [Cause], fixes: [RetryFix], exitCode: Int32, detail: String?,
                explanation: Explanation? = nil) {
        self.kind = kind; self.causes = causes; self.fixes = fixes
        self.exitCode = exitCode; self.detail = detail; self.explanation = explanation
    }

    public var succeeded: Bool { kind == .success }
}

public enum InstallLog {

    // Inno writes UTF-8; older or modified builds may write UTF-16 with a BOM.
    public static func read(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16)
        }
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    // Exit codes from Inno Setup's documentation.
    static let cancelledCodes: Set<Int32> = [2, 5]

    public static func diagnose(exitCode: Int32, log: String?, wineLog: String? = nil) -> InstallDiagnosis {
        let lines = (log ?? "").split(whereSeparator: \.isNewline).map { stripStamp(String($0)) }
        let wineLines = (wineLog ?? "").split(whereSeparator: \.isNewline).map { stripWineStamp(String($0)) }
        func first<Output>(_ pattern: Regex<Output>, in source: [String]? = nil) -> String? {
            (source ?? lines).first { (try? pattern.firstMatch(in: $0)) != nil }
        }

        if let line = first(/(?i)not enough (free )?(disk )?space|disk is full|there is not enough space|no space left/) {
            return InstallDiagnosis(kind: .diskSpace, causes: [.diskSpace], fixes: [], exitCode: exitCode, detail: line)
        }
        // The unpackers' error codes, even when the installer then exits 0 after rolling back.
        // A success log also names unarc.dll, when it is unpacked to {tmp}, so only error wording counts.
        if let line = first(/(?i)(unarc|isdone)\.dll returned an error code:\s*-?\d+/),
           let match = try? /error code:\s*(-?\d+)/.firstMatch(in: line) {
            switch Int(match.1) ?? 0 {
            case -2, -11, -12:
                return InstallDiagnosis(kind: .decompression, causes: [.memory, .path, .damagedFile],
                                        fixes: [.lessMemory, .fewerThreads, .verifyFiles, .shortPath],
                                        exitCode: exitCode, detail: line, explanation: .decompressorMemory)
            case -1, -3, -14:
                return InstallDiagnosis(kind: .decompression, causes: [.damagedFile, .memory, .path],
                                        fixes: [.verifyFiles, .lessMemory, .fewerThreads, .shortPath],
                                        exitCode: exitCode, detail: line, explanation: .decompressorData)
            case -6, -7:
                return InstallDiagnosis(kind: .decompression, causes: [.path, .diskSpace, .damagedFile],
                                        fixes: [.shortPath, .verifyFiles],
                                        exitCode: exitCode, detail: line, explanation: .decompressorIO)
            default:
                return InstallDiagnosis(kind: .decompression, causes: [.memory, .path, .damagedFile],
                                        fixes: [.verifyFiles, .fewerThreads, .lessMemory, .shortPath],
                                        exitCode: exitCode, detail: line, explanation: .helperFailed)
            }
        }
        // The extractor names the archive part it could not find.
        if let line = first(/(?i)not found any file specified for (isarc|unarc)extract|(source|data) file .*does not exist|file .* is missing/) {
            return InstallDiagnosis(kind: .missingPart, causes: [.missingPart], fixes: [],
                                    exitCode: exitCode, detail: line, explanation: .missingPart)
        }
        if let line = first(/(?i)returned an error code|archive data corrupted|decompression fails|(unarc|isdone)\.dll.*\b(error|failed)\b|\b(error|failed)\b.*(unarc|isdone)\.dll/) {
            return InstallDiagnosis(
                kind: .decompression, causes: [.memory, .path, .damagedFile],
                fixes: [.verifyFiles, .fewerThreads, .lessMemory, .shortPath],
                exitCode: exitCode, detail: line, explanation: .helperFailed)
        }
        if let line = first(/(?i)setup files are corrupted|crc (error|mismatch)|file is corrupt|is damaged/) {
            return InstallDiagnosis(kind: .damagedFile, causes: [.damagedFile], fixes: [.verifyFiles], exitCode: exitCode, detail: line)
        }
        if exitCode == 0 {
            return InstallDiagnosis(kind: .success, causes: [], fixes: [], exitCode: 0, detail: nil)
        }
        if cancelledCodes.contains(exitCode) || first(/(?i)user canceled|user cancelled|got eabort exception/) != nil {
            return InstallDiagnosis(kind: .cancelled, causes: [], fixes: [], exitCode: exitCode, detail: nil)
        }
        // The log ending at the temp dir means the setup died between unpacking its helpers and
        // its first page — a helper module the runner could not load or run.
        if let last = lines.last(where: { !$0.isEmpty }), last.hasPrefix("Created temporary directory") {
            return InstallDiagnosis(kind: .setupFailed, causes: [.runner], fixes: [.otherRunner, .shortPath],
                                    exitCode: exitCode, detail: last, explanation: .diedBeforeWizard)
        }
        let line = first(/(?i)^(exception message|error|fatal)/) ?? first(/(?i)\berror\b/)
            ?? first(/(?i)unhandled (exception|page fault)|cannot start application|bad exe format|\bfatal\b|\berror\b/, in: wineLines)
        return InstallDiagnosis(kind: .setupFailed, causes: [.runner, .path], fixes: [.otherRunner, .shortPath], exitCode: exitCode, detail: line)
    }

    static func stripStamp(_ line: String) -> String {
        line.replacing(/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}(\.\d+)?\s+/, with: "").trimmingCharacters(in: .whitespaces)
    }

    // Wine trace lines start with a thread id: "0024:err:seh:...".
    static func stripWineStamp(_ line: String) -> String {
        line.trimmingCharacters(in: .whitespaces)
    }
}
