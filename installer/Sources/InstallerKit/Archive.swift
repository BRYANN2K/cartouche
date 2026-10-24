// Reading and unpacking archives through the bundled libarchive (Contents/Helpers/
// libarchive.dylib). The engine is dlopen'd by the CArchive shim, so nothing links
// /usr/lib/libarchive and no bsdtar process ever runs.

import CArchive
import Foundation

public enum ArchiveFormat: String, Sendable, Equatable {
    case zip, sevenZip, rar, rar5, tar, iso9660, cab, unknown

    init(format: Int32, name: String) {
        switch format & CA_FORMAT_BASE_MASK {
        case CA_FORMAT_ZIP: self = .zip
        case CA_FORMAT_7ZIP: self = .sevenZip
        case CA_FORMAT_RAR: self = .rar
        case CA_FORMAT_RAR_V5: self = .rar5
        case CA_FORMAT_TAR: self = .tar
        case CA_FORMAT_ISO9660: self = .iso9660
        case CA_FORMAT_CAB: self = .cab
        default: self = .unknown
        }
        // A compressed tar still reports the TAR family; filters carry the codec.
        if self == .unknown, name.lowercased().contains("tar") { self = .tar }
    }
}

public struct ArchiveEntry: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case file, directory, symlink, hardlink, other
    }
    public var path: String
    public var size: Int64
    public var kind: Kind
    public var linkTarget: String?
    public var isEncrypted = false

    public init(path: String, size: Int64, kind: Kind, linkTarget: String? = nil, isEncrypted: Bool = false) {
        self.path = path
        self.size = size
        self.kind = kind
        self.linkTarget = linkTarget
        self.isEncrypted = isEncrypted
    }
}

public struct ArchiveProbe: Sendable, Equatable {
    public var format: ArchiveFormat
    // libarchive's own names, for diagnostics: "ZIP 4.5 (deflation)", "RAR v5".
    public var formatName: String
    // Compression filters between the file and the entries: "gzip", "xz", "zstd".
    public var filters: [String]
    public var entries: [ArchiveEntry]
    public var hasEncryptedEntries: Bool
    // Sum of file sizes; 0 means unknown.
    public var uncompressedSize: Int64

    public init(format: ArchiveFormat, formatName: String, filters: [String], entries: [ArchiveEntry],
                hasEncryptedEntries: Bool, uncompressedSize: Int64) {
        self.format = format
        self.formatName = formatName
        self.filters = filters
        self.entries = entries
        self.hasEncryptedEntries = hasEncryptedEntries
        self.uncompressedSize = uncompressedSize
    }
}

public struct ArchiveProgress: Sendable, Equatable {
    public var fileName: String
    public var bytesDone: Int64
    public var bytesTotal: Int64
    public var secondsLeft: TimeInterval?
}

public enum ArchiveError: Error, Sendable, Equatable {
    case engineUnavailable
    case engineLoadFailed(String)
    case passwordProtected
    case unsupportedFormat(String)
    case damaged(String)
    case unsafePath(String)
    case missingVolume(String)
    case insufficientSpace(needed: Int64, available: Int64)
    case writeFailed(String)
}

// Where an entry goes. `skip` drops links, specials and junk safely.
public enum EntryDestination: Sendable, Equatable {
    case skip
    case write(URL)
}

public protocol ArchiveEngine: Sendable {
    func probe(_ volumes: [URL]) throws -> ArchiveProbe
    // Probing a compressed tar decompresses the whole stream, so it polls for cancellation.
    func probe(_ volumes: [URL], isCancelled: @Sendable () -> Bool) throws -> ArchiveProbe
    // route decides each entry's destination; bytesDone reports written bytes.
    func extract(
        _ volumes: [URL],
        route: @Sendable (ArchiveEntry) throws -> EntryDestination,
        bytesDone: @Sendable (Int64) -> Void,
        isCancelled: @Sendable () -> Bool
    ) throws
}

extension ArchiveEngine {
    public func probe(_ volumes: [URL], isCancelled: @Sendable () -> Bool) throws -> ArchiveProbe {
        if isCancelled() { throw CancellationError() }
        return try probe(volumes)
    }
}

public final class LibarchiveEngine: ArchiveEngine, @unchecked Sendable {
    private let lib: OpaquePointer
    public let versionString: String

    public init(library path: String) throws {
        guard let lib = ca_open(path) else { throw ArchiveError.engineLoadFailed(path) }
        self.lib = lib
        versionString = String(cString: ca_version(lib))
    }

    deinit { ca_close(lib) }

    public func probe(_ volumes: [URL]) throws -> ArchiveProbe {
        try probe(volumes, isCancelled: { Task.isCancelled })
    }

    public func probe(_ volumes: [URL], isCancelled: @Sendable () -> Bool) throws -> ArchiveProbe {
        let reader = try open(volumes)
        defer { _ = ca_read_close(reader) }
        var entries: [ArchiveEntry] = []
        var encrypted = false
        var total: Int64 = 0
        while true {
            if isCancelled() { throw CancellationError() }
            let rc = ca_read_next(reader)
            if rc == CA_EOF { break }
            guard rc >= CA_WARN else { throw Self.map(reader) }
            let entry = ArchiveEntry(
                path: ca_entry_path(reader).map(String.init(cString:)) ?? "",
                size: ca_entry_size(reader),
                kind: Self.kind(ca_entry_type(reader), link: ca_entry_hardlink(reader) != nil),
                linkTarget: (ca_entry_symlink(reader) ?? ca_entry_hardlink(reader)).map(String.init(cString:)),
                isEncrypted: ca_entry_encrypted(reader) != 0)
            encrypted = encrypted || entry.isEncrypted
            if entry.kind == .file {
                let (sum, overflow) = total.addingReportingOverflow(max(0, entry.size))
                total = overflow ? .max : sum
            }
            entries.append(entry)
        }
        let encryptedFlag = ca_read_has_encrypted(reader)
        return ArchiveProbe(
            format: ArchiveFormat(format: ca_read_format(reader),
                                  name: ca_read_format_name(reader).map(String.init(cString:)) ?? ""),
            formatName: ca_read_format_name(reader).map(String.init(cString:)) ?? "",
            filters: (0 ..< max(0, ca_read_filter_count(reader))).compactMap {
                ca_read_filter_name(reader, $0).map(String.init(cString:))
            }.filter { $0 != "none" },
            entries: entries,
            hasEncryptedEntries: encrypted || encryptedFlag > 0,
            uncompressedSize: total)
    }

    public func extract(
        _ volumes: [URL],
        route: @Sendable (ArchiveEntry) throws -> EntryDestination,
        bytesDone: @Sendable (Int64) -> Void,
        isCancelled: @Sendable () -> Bool
    ) throws {
        let reader = try open(volumes)
        defer { _ = ca_read_close(reader) }
        // Entry names are already sanitised before they become absolute dest
        // paths, so SECURE_NOABSOLUTEPATHS (which would reject them) stays off.
        let flags = CA_EXTRACT_TIME | CA_EXTRACT_SECURE_SYMLINKS | CA_EXTRACT_SECURE_NODOTDOT
            | CA_EXTRACT_UNLINK | CA_EXTRACT_SPARSE
        guard let writer = ca_write_disk(lib, flags) else { throw ArchiveError.engineUnavailable }
        defer { _ = ca_write_close(writer) }
        var buffer = [UInt8](repeating: 0, count: 256 << 10)
        var written: Int64 = 0
        while true {
            if isCancelled() { throw CancellationError() }
            let rc = ca_read_next(reader)
            if rc == CA_EOF { break }
            guard rc >= CA_WARN else { throw Self.map(reader) }
            let entry = ArchiveEntry(
                path: ca_entry_path(reader).map(String.init(cString:)) ?? "",
                size: ca_entry_size(reader),
                kind: Self.kind(ca_entry_type(reader), link: ca_entry_hardlink(reader) != nil),
                linkTarget: (ca_entry_symlink(reader) ?? ca_entry_hardlink(reader)).map(String.init(cString:)),
                isEncrypted: ca_entry_encrypted(reader) != 0)
            guard case .write(let dest) = try route(entry) else {
                _ = ca_read_skip(reader)
                continue
            }
            dest.path(percentEncoded: false).withCString { ca_entry_set_path(reader, $0) }
            let header = ca_write_header(writer, reader)
            guard header >= CA_WARN else { throw Self.writeError(writer, header) }
            if entry.kind == .file {
                while true {
                    if isCancelled() { throw CancellationError() }
                    let n = buffer.withUnsafeMutableBytes { raw -> Int64 in
                        guard let base = raw.baseAddress else { return 0 }
                        return ca_read_data(reader, base, UInt64(raw.count))
                    }
                    if n < 0 { throw Self.map(reader) }
                    if n == 0 { break }
                    guard ca_write_data(writer, buffer, UInt64(n)) == n else {
                        throw Self.writeError(writer, CA_FAILED)
                    }
                    written += n
                    bytesDone(written)
                }
            }
            guard ca_write_finish_entry(writer) >= CA_WARN else { throw Self.writeError(writer, CA_FAILED) }
        }
    }

    private func open(_ volumes: [URL]) throws -> OpaquePointer {
        let pointers = volumes.map {
            UnsafePointer<CChar>(strdup($0.path(percentEncoded: false))!)
        }
        defer { pointers.forEach { free(UnsafeMutablePointer(mutating: $0)) } }
        let reader = pointers.withUnsafeBufferPointer { buffer -> OpaquePointer? in
            guard let base = buffer.baseAddress else { return nil }
            return ca_read_open(lib, base, Int32(buffer.count))
        }
        guard let reader else { throw ArchiveError.engineUnavailable }
        return reader
    }

    private static func kind(_ type: Int32, link hardlink: Bool) -> ArchiveEntry.Kind {
        if hardlink { return .hardlink }
        switch type {
        case CA_IFREG: return .file
        case CA_IFDIR: return .directory
        case CA_IFLNK: return .symlink
        default: return .other
        }
    }

    private static func map(_ reader: OpaquePointer) -> ArchiveError {
        let message = ca_read_error(reader).map(String.init(cString:)) ?? "read failed"
        let lower = message.lowercased()
        if lower.contains("encrypt") || lower.contains("passphrase") || lower.contains("password") {
            return .passwordProtected
        }
        if ca_read_errno(reader) == ENOENT {
            return .missingVolume(message)
        }
        if lower.contains("unrecognized") || lower.contains("not supported") {
            return .unsupportedFormat(message)
        }
        return .damaged(message)
    }

    private static func writeError(_ writer: OpaquePointer, _ status: Int32) -> ArchiveError {
        let message = ca_write_error(writer).map(String.init(cString:)) ?? "write failed \(status)"
        if ca_write_errno(writer) == ENOSPC {
            return .insufficientSpace(needed: -1, available: 0)
        }
        return .writeFailed(message)
    }
}

// How the bundled dylib is found, mirroring Innoextract.path.
public enum ArchiveSupport {

    // The pinned release installer/libarchive/build.sh produces.
    public static let version = "3.8.9"

    // CARTOUCHE_LIBARCHIVE, then the bundled copy.
    public static func path(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundled: [URL] = bundledCandidates(),
        fallbacks: [String] = []
    ) -> String? {
        let fm = FileManager.default
        var candidates: [String] = []
        #if DEBUG
        if let forced = environment["CARTOUCHE_LIBARCHIVE"], !forced.isEmpty { candidates.append(forced) }
        #endif
        candidates += bundled.map { $0.path(percentEncoded: false) }
        candidates += fallbacks
        return candidates.first { fm.fileExists(atPath: $0) }
    }

    public static func bundledCandidates(main: Bundle = .main) -> [URL] {
        var urls = [main.bundleURL.appending(path: "Contents/Helpers/libarchive.dylib")]
        if let exe = main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent() {
            urls.append(exe.appending(path: "../Helpers/libarchive.dylib").standardizedFileURL)
            urls.append(exe.appending(path: "libarchive.dylib"))
        }
        return urls
    }
}
