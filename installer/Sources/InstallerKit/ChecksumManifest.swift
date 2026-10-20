// Reads .md5 manifests shipped with installers and checks the parts natively, not the Windows checker.

import CryptoKit
import Foundation

public struct ChecksumEntry: Sendable, Equatable {
    public let md5: String
    public let file: URL
    public init(md5: String, file: URL) { self.md5 = md5; self.file = file }
}

public struct ChecksumManifest: Sendable {
    public let source: URL
    public let entries: [ChecksumEntry]
    // The manifest says some parts are optional downloads (languages, extras).
    public let mentionsOptionalParts: Bool
    public init(source: URL, entries: [ChecksumEntry], mentionsOptionalParts: Bool) {
        self.source = source; self.entries = entries; self.mentionsOptionalParts = mentionsOptionalParts
    }
}

public enum ChecksumResult: Sendable, Equatable {
    case ok
    case mismatch(expected: String, actual: String)
    case absent
}

public enum Checksums {

    public static func findManifest(in folder: URL) -> URL? {
        let fm = FileManager.default
        let top = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        let candidates = top + top.flatMap { url -> [URL] in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return [] }
            return (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
        }
        return candidates.first { $0.pathExtension.lowercased() == "md5" }
    }

    // Lines look like `d8396f99… *..\data-01.bin`. Paths are Windows-style and relative to the manifest, comments start with ';' or '#'.
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
            try Task.checkCancellation()
            hasher.update(data: chunk)
            progress?(Int64(chunk.count))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func damaged(_ results: [URL: ChecksumResult]) -> [String] {
        results.compactMap { url, result in
            if case .mismatch = result { return url.lastPathComponent }
            return nil
        }.sorted()
    }

    // Parts run side by side; progress gets the bytes hashed since its last call. Entries are hashed only inside
    // root: the folder the manifest was found in, since files like MD5/checksums.md5 refer to it as "..\". An entry
    // that escapes it is skipped.
    public static func verify(
        _ manifest: ChecksumManifest, root: URL? = nil,
        progress: (@Sendable (Int64) -> Void)? = nil
    ) async throws -> [URL: ChecksumResult] {
        let base = (root ?? manifest.source.deletingLastPathComponent()).standardizedFileURL
        var basePath = base.path(percentEncoded: false)
        while basePath.hasSuffix("/") { basePath.removeLast() }
        let prefix = basePath + "/"
        let entries = manifest.entries.filter {
            $0.file.standardizedFileURL.path(percentEncoded: false).hasPrefix(prefix)
        }
        return try await withThrowingTaskGroup(of: (URL, ChecksumResult).self) { group in
            var iterator = entries.makeIterator()
            var running = 0
            // A manifest can name thousands of files; hash a few at a time.
            while running < 8, let entry = iterator.next() {
                running += 1
                group.addTask {
                    guard let values = try? entry.file.resourceValues(forKeys: [.isRegularFileKey]),
                          values.isRegularFile == true else { return (entry.file, .absent) }
                    guard let actual = try? md5(of: entry.file, progress: progress) else { return (entry.file, .absent) }
                    return (entry.file, actual == entry.md5 ? .ok : .mismatch(expected: entry.md5, actual: actual))
                }
            }
            var results: [URL: ChecksumResult] = [:]
            while let (url, result) = try await group.next() {
                results[url] = result
                running -= 1
                if let entry = iterator.next() {
                    running += 1
                    group.addTask {
                        guard let values = try? entry.file.resourceValues(forKeys: [.isRegularFileKey]),
                              values.isRegularFile == true else { return (entry.file, .absent) }
                        guard let actual = try? md5(of: entry.file, progress: progress) else { return (entry.file, .absent) }
                        return (entry.file, actual == entry.md5 ? .ok : .mismatch(expected: entry.md5, actual: actual))
                    }
                }
            }
            // A cancelled run marks files .absent instead of throwing; don't report that.
            try Task.checkCancellation()
            return results
        }
    }
}
