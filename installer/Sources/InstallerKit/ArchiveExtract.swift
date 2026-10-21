// Multi-volume sets, safe entry routing, and the staging folder extraction.

import CArchive
import Foundation

public struct VolumeSet: Sendable, Equatable {
    // Ordered volumes for the engine, starting at the first.
    public var volumes: [URL]
    // Names absent from the middle of the numbering, e.g. "game.part2.rar".
    public var missing: [String]
}

public enum ArchiveVolumes {

    nonisolated(unsafe) private static let partRar = /^(?i)(.*)\.part(\d+)\.rar$/
    nonisolated(unsafe) private static let oldRar = /^(?i)(.*)\.r(\d{2,})$/
    nonisolated(unsafe) private static let numbered = /^(?i)(.*\.(?:7z|zip))\.(\d{3,})$/
    nonisolated(unsafe) private static let zipDisk = /^(?i)(.*)\.z(\d{2,})$/

    // Given any volume of a multi-volume archive (or a single archive), the
    // ordered set it belongs to. A gap in the middle is named in `missing`.
    public static func set(for url: URL, listing: (URL) -> [URL] = siblings) -> VolumeSet? {
        let name = url.lastPathComponent
        let folder = url.deletingLastPathComponent()
        let names = listing(folder)
        if let m = try? partRar.wholeMatch(in: name) {
            let stem = String(m.1)
            let width = m.2.count
            let found = matches(in: names) { n in
                (try? partRar.wholeMatch(in: n)).flatMap {
                    $0.1.lowercased() == stem.lowercased() ? Int($0.2) : nil
                }
            }
            return group(names: names, index: { "\(stem).part\(padded($0, width)).rar" }, found: found)
        }
        if let m = try? oldRar.wholeMatch(in: name) {
            return rarChain(names: names, stem: String(m.1), width: m.2.count)
        }
        if name.lowercased().hasSuffix(".rar") {
            return rarChain(names: names, stem: String(name.dropLast(4)), width: 2)
        }
        if let m = try? numbered.wholeMatch(in: name) {
            let base = String(m.1)
            let width = m.2.count
            let found = matches(in: names) { n in
                (try? numbered.wholeMatch(in: n)).flatMap {
                    $0.1.lowercased() == base.lowercased() ? Int($0.2) : nil
                }
            }
            return group(names: names, index: { "\(base).\(padded($0, width))" }, found: found)
        }
        if let m = try? zipDisk.wholeMatch(in: name) {
            let stem = String(m.1)
            let found = zipDisks(in: names, stem: stem)
            return group(names: names, first: "\(stem).zip",
                         index: { "\(stem).z\(padded($0 - 1, m.2.count))" }, found: found)
        }
        if name.lowercased().hasSuffix(".zip") {
            // name.zip can head a name.z01, name.z02 disk chain.
            let found = zipDisks(in: names, stem: String(name.dropLast(4)))
            guard !found.isEmpty else { return nil }
            return group(names: names, first: name,
                         index: { "\(String(name.dropLast(4))).z\(padded($0 - 1, 2))" },
                         found: found)
        }
        return nil
    }

    private static func padded(_ n: Int, _ width: Int) -> String {
        let s = String(n)
        return s.count >= width ? s : String(repeating: "0", count: width - s.count) + s
    }

    // A .rar volume followed by .r00, .r01, ... where .r00 is volume 2.
    private static func rarChain(names: [URL], stem: String, width: Int) -> VolumeSet {
        var found = matches(in: names) { n in
            (try? oldRar.wholeMatch(in: n)).flatMap {
                $0.1.lowercased() == stem.lowercased() ? (Int($0.2) ?? 0) + 2 : nil
            }
        }
        if let first = names.first(where: { $0.lastPathComponent.lowercased() == stem.lowercased() + ".rar" }) {
            found[first.lastPathComponent.lowercased()] = 1
        }
        return group(names: names, first: stem + ".rar",
                     index: { "\(stem).r\(padded($0 - 2, width))" }, found: found)
    }

    private static func zipDisks(in names: [URL], stem: String) -> [String: Int] {
        matches(in: names) { n in
            (try? zipDisk.wholeMatch(in: n)).flatMap {
                $0.1.lowercased() == stem.lowercased() ? (Int($0.2) ?? 0) + 1 : nil
            }
        }
    }

    // file name (lowercased) → volume number, for siblings that fit the pattern
    private static func matches(in names: [URL], number: (String) -> Int?) -> [String: Int] {
        var found: [String: Int] = [:]
        for url in names {
            if let n = number(url.lastPathComponent) { found[url.lastPathComponent.lowercased()] = n }
        }
        return found
    }

    private static func group(names: [URL], first: String? = nil,
                              index: (Int) -> String, found: [String: Int]) -> VolumeSet {
        // Only the contiguous prefix can be read; anything past a gap is
        // unreachable, so volumes stop at the first absent number.
        let head = first ?? index(1)
        let max = found.values.max() ?? 1
        var volumes: [URL] = []
        var missing: [String] = []
        for n in 1 ... max {
            let expected = n == 1 ? head.lowercased() : index(n).lowercased()
            if let actual = names.first(where: { $0.lastPathComponent.lowercased() == expected }) {
                if missing.isEmpty { volumes.append(actual) }
            } else {
                missing.append(n == 1 ? head : index(n))
            }
        }
        return VolumeSet(volumes: volumes, missing: missing)
    }

    public static func siblings(_ folder: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
    }
}

// Path sanitization and entry policy, kept pure so tests exercise it through the fake too.
public enum EntryRouting {

    public struct Limits: Sendable {
        public var maxEntries = 500_000
        public var maxBytes: Int64 = 1 << 40
        public var maxPath = 1024
        public init() {}
    }

    // The entry's destination under root, or .skip for links and specials.
    // Pathnames that would escape root are an error, not a best-effort fix.
    public static func destination(for entry: ArchiveEntry, under root: URL, limits: Limits = .init()) throws -> EntryDestination {
        if entry.isEncrypted { throw ArchiveError.passwordProtected }
        guard let relative = try sanitize(entry.path, maxPath: limits.maxPath) else { return .skip }
        switch entry.kind {
        case .file, .directory:
            return .write(root.appending(path: relative))
        case .symlink, .hardlink, .other:
            return .skip
        }
    }

    // nil when nothing is left (a "." entry); throws on absolute paths and
    // ".." that climbs out of the archive's root.
    static func sanitize(_ raw: String, maxPath: Int) throws -> String? {
        guard !raw.isEmpty, !raw.contains("\0") else { return nil }
        if raw.hasPrefix("/") || raw.hasPrefix("\\") || raw.hasPrefix("~") {
            throw ArchiveError.unsafePath(raw)
        }
        var components: [String] = []
        for part in raw.split(whereSeparator: { $0 == "/" || $0 == "\\" }) {
            let name = String(part)
            if name == "." || name.isEmpty { continue }
            if name == ".." {
                guard !components.isEmpty else { throw ArchiveError.unsafePath(raw) }
                components.removeLast()
                continue
            }
            components.append(name)
        }
        // A drive prefix on the first component ("C:\...").
        if let first = components.first, first.count == 2, first.hasSuffix(":") {
            throw ArchiveError.unsafePath(raw)
        }
        guard !components.isEmpty else { return nil }
        let joined = components.joined(separator: "/")
        guard joined.count <= maxPath else { throw ArchiveError.unsafePath(raw) }
        return joined
    }
}

public struct ExtractionResult: Sendable, Equatable {
    // The staging folder's final location, after the move.
    public var root: URL
    public var files: Int
    // Bytes actually written.
    public var bytes: Int64
    // Symlinks, hardlinks and special entries dropped by policy.
    public var skipped: [String]
}

// Shared mutable state for the @Sendable route/progress closures; the engine's
// extraction loop is single-threaded, so plain fields are safe.
final class ExtractionState: @unchecked Sendable {
    var entries = 0
    var declared: Int64 = 0
    var written: Int64 = 0
    var current = ""
    var skipped: [String] = []
}

public struct ArchiveExtractor: Sendable {

    public var engine: any ArchiveEngine
    public var limits = EntryRouting.Limits()
    // Free space wanted on top of the probed uncompressed size.
    public var spaceMargin = 1.15
    public var spaceReserve: Int64 = 64 << 20
    // Free-space source; injectable because sandboxes report 0.
    public var freeBytes: @Sendable (URL) -> Int64?

    public init(
        engine: any ArchiveEngine,
        limits: EntryRouting.Limits = .init(),
        freeBytes: (@Sendable (URL) -> Int64?)? = nil
    ) {
        self.engine = engine
        self.limits = limits
        self.freeBytes = freeBytes ?? Disk.freeBytes
    }

    // The engine resolved from the bundled dylib, when it exists.
    public static func live() throws -> ArchiveExtractor {
        // The app puts the dylib in Contents/Helpers, which is on the
        // executable's rpath, so the install name resolves where path()
        // cannot look.
        let path = ArchiveSupport.path() ?? "@rpath/libarchive.dylib"
        return ArchiveExtractor(engine: try LibarchiveEngine(library: path))
    }

    public func volumes(for url: URL) throws -> [URL] {
        guard let set = ArchiveVolumes.set(for: url) else { return [url] }
        if let name = set.missing.first { throw ArchiveError.missingVolume(name) }
        guard !set.volumes.isEmpty else { throw ArchiveError.missingVolume(url.lastPathComponent) }
        return set.volumes
    }

    public func probe(_ url: URL) throws -> ArchiveProbe {
        try engine.probe(volumes(for: url))
    }

    // Extracts under a staging folder next to the destination, checks space
    // against the probe first, then moves the result into place.
    @discardableResult
    public func extract(
        _ url: URL, to parent: URL,
        progress: @Sendable (ArchiveProgress) -> Void = { _ in },
        isCancelled: @Sendable () -> Bool = { false }
    ) throws -> ExtractionResult {
        let volumes = try volumes(for: url)
        let probe = try engine.probe(volumes)
        if probe.hasEncryptedEntries { throw ArchiveError.passwordProtected }

        let needed = Int64(Double(probe.uncompressedSize) * spaceMargin) + spaceReserve
        if let free = freeBytes(parent), free < needed {
            throw ArchiveError.insufficientSpace(needed: needed, available: free)
        }

        let fm = FileManager.default
        // Real path: write_disk's SECURE_SYMLINKS refuses to work through a
        // symlinked component, and /var is one on macOS.
        let staging = Self.realPath(parent)
            .appending(path: ".cartouche-drop-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        let state = ExtractionState()
        state.current = url.lastPathComponent
        do {
            let start = Date()
            let route: @Sendable (ArchiveEntry) throws -> EntryDestination = { entry in
                state.entries += 1
                if state.entries > self.limits.maxEntries { throw ArchiveError.damaged("too many entries") }
                state.current = entry.path
                if entry.kind == .file {
                    state.declared += entry.size
                    if state.declared > self.limits.maxBytes {
                        throw ArchiveError.damaged("archive expands past its limit")
                    }
                }
                let dest = try EntryRouting.destination(for: entry, under: staging, limits: self.limits)
                if dest == .skip { state.skipped.append(entry.path) }
                return dest
            }
            let report: @Sendable (Int64) -> Void = { bytes in
                state.written = bytes
                let elapsed = Date().timeIntervalSince(start)
                let left: TimeInterval? = probe.uncompressedSize > 0 && elapsed > 1 && bytes > 0
                    ? max(0, Double(probe.uncompressedSize - bytes) / (Double(bytes) / elapsed)) : nil
                progress(ArchiveProgress(fileName: state.current, bytesDone: bytes,
                                         bytesTotal: max(probe.uncompressedSize, bytes), secondsLeft: left))
            }
            try engine.extract(volumes, route: route, bytesDone: report, isCancelled: isCancelled)

            var files = 0
            if let walk = fm.enumerator(at: staging, includingPropertiesForKeys: [.isRegularFileKey]) {
                for case let f as URL in walk where (try? f.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                    files += 1
                }
            }
            let final = Self.unique(parent.appending(path: Self.cleanName(of: url)))
            try fm.moveItem(at: staging, to: final)
            return ExtractionResult(root: final, files: files, bytes: state.written, skipped: state.skipped)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }

    static func realPath(_ url: URL) -> URL {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard url.path(percentEncoded: false).withCString({ realpath($0, &buffer) }) != nil else { return url }
        return URL(fileURLWithPath: String(cString: buffer), isDirectory: true)
    }

    static func cleanName(of url: URL) -> String {
        var name = url.lastPathComponent
        let lower = name.lowercased()
        if let m = try? /^(?i)(.*)\.part0*\d+\.rar$/.wholeMatch(in: name) {
            name = String(m.1)
        } else if let m = try? /^(?i)(.*\.(?:7z|zip))\.(\d{3,})$/.wholeMatch(in: name) {
            name = (String(m.1) as NSString).deletingPathExtension
        } else {
            for suffix in [".tar.gz", ".tar.xz", ".tar.bz2", ".tar.zst", ".tar.lz", ".tgz", ".tbz2", ".txz"]
            where lower.hasSuffix(suffix) {
                name = String(name.dropLast(suffix.count))
                return name.isEmpty ? "Archive" : name
            }
            name = (name as NSString).deletingPathExtension
        }
        return name.isEmpty ? "Archive" : name
    }

    static func unique(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path(percentEncoded: false)) else { return url }
        for n in 2 ... 100 {
            let candidate = url.deletingLastPathComponent()
                .appending(path: "\(url.lastPathComponent) \(n)")
            if !fm.fileExists(atPath: candidate.path(percentEncoded: false)) { return candidate }
        }
        return url.appendingPathExtension(UUID().uuidString)
    }
}
