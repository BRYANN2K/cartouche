// Reads .md5 manifests shipped with installers and checks the parts natively,
// instead of running the Windows checker they come with.

import CryptoKit
import Foundation

public struct ChecksumEntry: Sendable, Equatable {
    public let md5: String
    public let file: URL
}

public struct ChecksumManifest: Sendable {
    public let source: URL
    public let entries: [ChecksumEntry]
    // The manifest says some parts are optional downloads (languages, extras).
    public let mentionsOptionalParts: Bool
}

public enum ChecksumResult: Sendable, Equatable {
    case ok
    case mismatch(expected: String, actual: String)
    case absent
}

public enum Checksums {

    // Looks in the folder and one level down (MD5/, Verify/).
    public static func findManifest(in folder: URL) -> URL? {
        let fm = FileManager.default
        let top = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        let candidates = top + top.flatMap { url -> [URL] in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return [] }
            return (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
        }
        return candidates.first { $0.pathExtension.lowercased() == "md5" }
    }

    // Lines look like `d8396f99… *..\data-01.bin`. Paths are Windows-style and
    // relative to the manifest, comments start with ';' or '#'.
    public static func parse(_ manifest: URL) throws -> ChecksumManifest {
        let text = try String(contentsOf: manifest, encoding: .utf8)
        let base = manifest.deletingLastPathComponent()
        var entries: [ChecksumEntry] = []
        var optional = false
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix(";") || line.hasPrefix("#") {
                if line.localizedCaseInsensitiveContains("selective") || line.localizedCaseInsensitiveContains("optional") { optional = true }
                continue
            }
            guard let match = try? /^([0-9a-fA-F]{32})\s+\*?(.+)$/.wholeMatch(in: line) else { continue }
            let path = String(match.2).replacingOccurrences(of: "\\", with: "/")
            entries.append(ChecksumEntry(md5: match.1.lowercased(), file: base.appending(path: path).standardizedFileURL))
        }
        return ChecksumManifest(source: manifest, entries: entries, mentionsOptionalParts: optional)
    }

    public static func md5(of file: URL, progress: (@Sendable (Int64) -> Void)? = nil) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = Insecure.MD5()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
            progress?(Int64(chunk.count))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // One file per task: a single MD5 stream can't be split, but parts can run side by side.
    // progress gets the bytes hashed since its last call, from any part.
    public static func verify(
        _ manifest: ChecksumManifest, progress: (@Sendable (Int64) -> Void)? = nil
    ) async -> [URL: ChecksumResult] {
        await withTaskGroup(of: (URL, ChecksumResult).self) { group in
            for entry in manifest.entries {
                group.addTask {
                    guard FileManager.default.fileExists(atPath: entry.file.path(percentEncoded: false)) else { return (entry.file, .absent) }
                    guard let actual = try? md5(of: entry.file, progress: progress) else { return (entry.file, .absent) }
                    return (entry.file, actual == entry.md5 ? .ok : .mismatch(expected: entry.md5, actual: actual))
                }
            }
            var results: [URL: ChecksumResult] = [:]
            for await (url, result) in group { results[url] = result }
            return results
        }
    }
}
