import CryptoKit
import Foundation

// Where cores come from: the libretro buildbot, for Apple silicon
public struct CoreSource: Sendable, Equatable {
    public var cores: URL
    public var info: URL

    public init(cores: URL, info: URL) {
        self.cores = cores
        self.info = info
    }

    public static let buildbot = CoreSource(
        cores: URL(string: "https://buildbot.libretro.com/nightly/apple/osx/arm64/latest/")!,
        info: URL(string: "https://buildbot.libretro.com/assets/frontend/info.zip")!
    )
}

// A core as it was when Cartouche downloaded it. The buildbot signs nothing, so what was seen the first time is what every launch checks against.
public struct CoreRecord: Codable, Sendable, Equatable {
    public var core: String
    public var file: String
    public var size: Int64
    public var sha256: String
    public var source: URL
    public var recorded: Date
}

public enum CoreCheck: Sendable, Equatable {
    case verified
    case missing
    case unrecorded
    case changed
}

public enum CoreError: Error, Equatable, LocalizedError {
    case downloadFailed(core: String, detail: String)
    case notACore(core: String)
    case damaged(core: String)
    case missing(core: String)

    public var errorDescription: String? {
        switch self {
        case .downloadFailed:
            String(localized: "Core download failed, try again later.", bundle: .module)
        case .notACore(let core):
            String(localized: "The \(core) download is not a core for this Mac.", bundle: .module)
        case .damaged(let core):
            String(localized: "The \(core) core changed since it was downloaded. Update it in Settings > Consoles.", bundle: .module)
        case .missing(let core):
            String(localized: "The \(core) core is not downloaded yet.", bundle: .module)
        }
    }
}

// Downloads, checks, updates and deletes cores in the cores folder. Nothing else is written there, and nothing outside it is deleted.
public actor CoreManager {

    public let paths: RetroArchPaths
    public let source: CoreSource
    private let session: URLSession

    public init(paths: RetroArchPaths, source: CoreSource = .buildbot, session: URLSession = .shared) {
        self.paths = paths
        self.source = source
        self.session = session
    }

    public func records() -> [CoreRecord] {
        guard let data = try? Data(contentsOf: paths.coreRecords),
              let records = try? Self.decoder.decode([CoreRecord].self, from: data)
        else { return [] }
        return records.sorted { $0.core < $1.core }
    }

    public func record(_ core: String) -> CoreRecord? { records().first { $0.core == core } }

    public nonisolated func url(_ core: String) -> URL { paths.cores.appending(path: Self.file(core)) }

    public func check(_ core: String) -> CoreCheck {
        let file = url(core)
        guard FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) else { return .missing }
        guard let record = record(core) else { return .unrecorded }
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, Int64(size) == record.size,
              (try? Self.sha256(file)) == record.sha256
        else { return .changed }
        return .verified
    }

    public func ready(_ core: String) throws -> URL {
        switch check(core) {
        case .verified: return url(core)
        case .missing: throw CoreError.missing(core: core)
        case .unrecorded, .changed: throw CoreError.damaged(core: core)
        }
    }

    @discardableResult
    public func install(_ core: String) async throws -> CoreRecord {
        if check(core) == .verified, let record = record(core) {
            try await installInfo(core, refresh: false)
            return record
        }
        return try await download(core)
    }

    @discardableResult
    public func update(_ core: String) async throws -> CoreRecord {
        try await download(core, refreshInfo: true)
    }

    public func delete(_ core: String) throws {
        let file = url(core)
        if FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: file)
        }
        try save(records().filter { $0.core != core })
    }

    private func download(_ core: String, refreshInfo: Bool = false) async throws -> CoreRecord {
        try paths.create()
        let name = Self.file(core)
        let remote = source.cores.appending(path: "\(name).zip")
        let work = paths.downloads.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let archive = try await fetch(remote, core: core, into: work)
        // Only the member named as the core is taken out of the archive
        let unpacked = work.appending(path: "unpacked", directoryHint: .isDirectory)
        guard Self.unzip(archive, member: name, into: unpacked) else { throw CoreError.notACore(core: core) }
        let fresh = unpacked.appending(path: name)
        guard Self.isMachO(fresh) else { throw CoreError.notACore(core: core) }

        let size = Int64(try fresh.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        let record = CoreRecord(
            core: core, file: name, size: size, sha256: try Self.sha256(fresh), source: remote,
            recorded: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)))
        try Self.place(fresh, at: url(core))
        try save(records().filter { $0.core != core } + [record])
        try await installInfo(core, refresh: refreshInfo)
        return record
    }

    private func installInfo(_ core: String, refresh: Bool) async throws {
        let target = paths.coreInfo.appending(path: "\(core)_libretro.info")
        if !refresh, FileManager.default.fileExists(atPath: target.path(percentEncoded: false)) { return }
        let work = paths.downloads.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let archive = try await fetch(source.info, core: core, into: work)
        let unpacked = work.appending(path: "unpacked", directoryHint: .isDirectory)
        guard Self.unzip(archive, member: "\(core)_libretro.info", into: unpacked) else { return }
        try FileManager.default.createDirectory(at: paths.coreInfo, withIntermediateDirectories: true)
        try Self.place(unpacked.appending(path: "\(core)_libretro.info"), at: target)
    }

    private func fetch(_ remote: URL, core: String, into work: URL) async throws -> URL {
        let body: URL, response: URLResponse
        do {
            (body, response) = try await session.download(from: remote)
        } catch {
            throw CoreError.downloadFailed(core: core, detail: error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            try? FileManager.default.removeItem(at: body)
            throw CoreError.downloadFailed(core: core, detail: "\(remote.lastPathComponent): HTTP \(http.statusCode)")
        }
        let archive = work.appending(path: remote.lastPathComponent)
        try FileManager.default.moveItem(at: body, to: archive)
        return archive
    }

    private func save(_ records: [CoreRecord]) throws {
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        try Self.encoder.encode(records.sorted { $0.core < $1.core }).write(to: paths.coreRecords, options: .atomic)
    }

    static func file(_ core: String) -> String { "\(core)_libretro.dylib" }

    static func place(_ fresh: URL, at target: URL) throws {
        if FileManager.default.fileExists(atPath: target.path(percentEncoded: false)) {
            _ = try FileManager.default.replaceItemAt(target, withItemAt: fresh)
        } else {
            try FileManager.default.moveItem(at: fresh, to: target)
        }
    }

    static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // 64-bit Mach-O, or a universal binary
    static func isMachO(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url),
              let head = try? handle.read(upToCount: 4), head.count == 4
        else { return false }
        try? handle.close()
        return [[0xCF, 0xFA, 0xED, 0xFE], [0xCA, 0xFE, 0xBA, 0xBE]].contains(Array(head))
    }

    static func unzip(_ archive: URL, member: String, into folder: URL) -> Bool {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        // -j drops any folder in the member's path, so nothing lands outside
        unzip.arguments = ["-q", "-o", "-j", archive.path(percentEncoded: false), member, "-d", folder.path(percentEncoded: false)]
        unzip.standardOutput = FileHandle.nullDevice
        unzip.standardError = FileHandle.nullDevice
        guard (try? unzip.run()) != nil else { return false }
        unzip.waitUntilExit()
        return unzip.terminationStatus == 0
            && FileManager.default.fileExists(atPath: folder.appending(path: member).path(percentEncoded: false))
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
