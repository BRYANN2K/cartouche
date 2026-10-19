// Names the likely cause of a failed install from the exit code and the log
// Inno Setup writes with /LOG, and says which retries may help.

import Foundation

public enum RetryFix: String, Sendable, CaseIterable, Codable {
    case verifyFiles, fewerThreads, lessMemory, shortPath, otherRunner
}

public struct InstallDiagnosis: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case success, cancelled, decompression, diskSpace, damagedFile, setupFailed
    }

    public enum Cause: String, Sendable, Equatable {
        case memory, path, damagedFile, diskSpace, runner
    }

    public let kind: Kind
    // Most likely first.
    public let causes: [Cause]
    public let fixes: [RetryFix]
    public let exitCode: Int32
    // The log line that decided it, without its time stamp.
    public let detail: String?

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

    public static func diagnose(exitCode: Int32, log: String?) -> InstallDiagnosis {
        let lines = (log ?? "").split(whereSeparator: \.isNewline).map { stripStamp(String($0)) }
        func first<Output>(_ pattern: Regex<Output>) -> String? {
            lines.first { (try? pattern.firstMatch(in: $0)) != nil }
        }

        // Space first: unarc also reports a full disk, and then memory is not the cause.
        if let line = first(/(?i)not enough (free )?(disk )?space|disk is full|there is not enough space|no space left/) {
            return InstallDiagnosis(kind: .diskSpace, causes: [.diskSpace], fixes: [], exitCode: exitCode, detail: line)
        }
        // The decompressors' errors, even when the installer then exits 0 after rolling back.
        // A success log also names unarc.dll, when it is unpacked to {tmp}, so only error wording counts.
        if let line = first(/(?i)returned an error code|archive data corrupted|decompression fails|not found any file specified for isarcextract|(unarc|isdone)\.dll.*\b(error|failed)\b|\b(error|failed)\b.*(unarc|isdone)\.dll/) {
            return InstallDiagnosis(
                kind: .decompression, causes: [.memory, .path, .damagedFile],
                fixes: [.verifyFiles, .fewerThreads, .lessMemory, .shortPath], exitCode: exitCode, detail: line)
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
        let line = first(/(?i)^(exception message|error|fatal)/) ?? first(/(?i)\berror\b/)
        return InstallDiagnosis(kind: .setupFailed, causes: [.runner, .path], fixes: [.otherRunner, .shortPath], exitCode: exitCode, detail: line)
    }

    // "2026-10-19 21:04:11.102   Message" → "Message"
    static func stripStamp(_ line: String) -> String {
        line.replacing(/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}(\.\d+)?\s+/, with: "").trimmingCharacters(in: .whitespaces)
    }
}
