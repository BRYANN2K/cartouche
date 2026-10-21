// Output verification (ADR 0025/0026): installed state and verification state stay separate.
// Evidence picks the level — a shipped checksum list or archive CRC is full, the installer
// script's file list and sizes is partial, nothing usable is "Installed, not verified". A
// successful extractor exit or a present exe never counts as verified.

import Foundation
import InstallerKit

// A file the installer script promised, relative to the install dir.
struct VerificationFile: Codable, Sendable, Equatable {
    var path: String
    var bytes: Int64
}

// Which evidence produced the status; full verification comes from manifest/crc/supplied.
enum VerificationLevel: String, Codable, Sendable, Equatable {
    case manifest
    case crc
    case supplied
    case sizes
    case unavailable
}

// One run's result; a mismatch carries the names that failed, for the sheet and the log.
struct VerificationOutcome: Sendable, Equatable {
    var status: GameVerificationStatus
    var level: VerificationLevel
    var mismatched: [String] = []
    // Persisted for later checks: the manifest's path relative to the game dir, and the
    // script's file list — still usable after the installer folder is gone.
    var manifest: String?
    var files: [VerificationFile]?
}

// The record's verification half, next to — never inside — the installed state.
struct VerificationRecord: Codable, Sendable, Equatable {
    var status: GameVerificationStatus
    var level: VerificationLevel
    var checkedAt: Date
    var gameDir: String?
    var manifest: String?
    var files: [VerificationFile]?
    var mismatched: [String]

    init(outcome: VerificationOutcome, gameDir: URL, checkedAt: Date = Date()) {
        status = outcome.status
        level = outcome.level
        self.checkedAt = checkedAt
        self.gameDir = gameDir.path(percentEncoded: false)
        manifest = outcome.manifest
        files = outcome.files
        mismatched = outcome.mismatched
    }

    init(status: GameVerificationStatus, checkedAt: Date = Date()) {
        self.status = status
        level = .unavailable
        self.checkedAt = checkedAt
        mismatched = []
    }
}

// The checks themselves: plain statics so both the install gate and the later Verify Files…
// run the same code, off whichever actor calls them.
enum GameVerify {

    // Full: every entry inside the root hashed, sequentially so progress can name the file.
    static func checkManifest(
        _ manifest: ChecksumManifest, root: URL, perFile delay: Duration = .zero,
        progress: (@Sendable (Int, Int, String) -> Void)? = nil
    ) async throws -> [String] {
        let inside = entries(manifest, under: root)
        var bad: [String] = []
        var done = 0
        for entry in inside {
            try Task.checkCancellation()
            if delay > .zero { try await Task.sleep(for: delay) }
            let name = relative(entry.file, under: root)
            let ok = (try? entry.file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            if !ok || (try? Checksums.md5(of: entry.file)) != entry.md5.lowercased() {
                bad.append(name)
            }
            done += 1
            progress?(done, inside.count, name)
        }
        return bad.sorted()
    }

    // Partial: the script's file list, checked for presence and byte size.
    static func checkSizes(
        _ files: [VerificationFile], root: URL, perFile delay: Duration = .zero,
        progress: (@Sendable (Int, Int, String) -> Void)? = nil
    ) async throws -> [String] {
        var bad: [String] = []
        var done = 0
        for file in files {
            try Task.checkCancellation()
            if delay > .zero { try await Task.sleep(for: delay) }
            let url = root.appending(path: file.path)
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values?.isRegularFile != true || Int64(values?.fileSize ?? -1) != file.bytes {
                bad.append(file.path)
            }
            done += 1
            progress?(done, files.count, file.path)
        }
        return bad.sorted()
    }

    // A manifest counts as output evidence only when it names at least one file that exists
    // under the install dir — one describing only absent files belongs to the parts, not this
    // output.
    static func usableManifest(at url: URL, root: URL) -> ChecksumManifest? {
        guard let parsed = try? Checksums.parse(url), !parsed.entries.isEmpty else { return nil }
        let inside = entries(parsed, under: root)
        guard inside.contains(where: {
            (try? $0.file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }) else { return nil }
        return ChecksumManifest(source: url, entries: inside, mentionsOptionalParts: parsed.mentionsOptionalParts)
    }

    static func entries(_ manifest: ChecksumManifest, under root: URL) -> [ChecksumEntry] {
        var base = root.standardizedFileURL.path(percentEncoded: false)
        while base.hasSuffix("/") { base.removeLast() }
        return manifest.entries.filter {
            $0.file.standardizedFileURL.path(percentEncoded: false).hasPrefix(base + "/")
        }
    }

    // A supplied list is read against the game dir wherever the file itself lives: `..\game.exe`
    // and `game.exe` both name <gameDir>/game.exe.
    static func suppliedManifest(_ manifest: URL, gameDir: URL) throws -> ChecksumManifest {
        let text = try String(contentsOf: manifest, encoding: .utf8)
        var entries: [ChecksumEntry] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix(";") || line.hasPrefix("#") { continue }
            guard let match = try? /^([0-9a-fA-F]{32})\s+\*?(.+)$/.wholeMatch(in: line) else { continue }
            let parts = String(match.2).replacingOccurrences(of: "\\", with: "/")
                .split(separator: "/").map(String.init)
                .filter { $0 != "." && $0 != ".." }
            guard !parts.isEmpty else { continue }
            entries.append(ChecksumEntry(
                md5: match.1.lowercased(), file: parts.reduce(gameDir) { $0.appending(path: $1) }))
        }
        return ChecksumManifest(source: manifest, entries: entries, mentionsOptionalParts: false)
    }

    // The script's file list narrowed to what lands in the install dir: the app section.
    static func installedFiles(from entries: [InnoFileEntry]) -> [VerificationFile] {
        entries.compactMap { entry in
            let path = entry.path.replacingOccurrences(of: "\\", with: "/")
            guard path.lowercased().hasPrefix("app/") else { return nil }
            let rel = String(path.dropFirst(4))
            return rel.isEmpty ? nil : VerificationFile(path: rel, bytes: entry.bytes)
        }
    }

    static func relative(_ url: URL, under root: URL) -> String {
        var base = root.standardizedFileURL.path(percentEncoded: false)
        while base.hasSuffix("/") { base.removeLast() }
        let path = url.standardizedFileURL.path(percentEncoded: false)
        return path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : url.lastPathComponent
    }
}
