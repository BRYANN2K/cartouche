import CryptoKit
import Foundation

// What one dropped or found file turned out to be
public struct Identification: Sendable, Identifiable, Equatable {
    // What RetroArch loads: the cartridge, the .cue, or the .m3u of a set
    public var file: URL
    // Each disc of an .m3u set, in order
    public var discs: [URL] = []
    public var console: String?
    public var databaseName: String?
    public var name: String
    // nil: not recognized, the user picks the console
    public var identifiedBy: IdentifiedBy?
    // Consoles whose files have this extension, offered first in the picker
    public var candidates: [String] = []
    // The whole file's CRC32, when identification already read it; netplay
    // room matching reuses it instead of reading the file again
    public var crc: UInt32?

    public var id: String { file.path(percentEncoded: false) }

    public var isRecognized: Bool { identifiedBy != nil && console != nil }

    // The library entry, with the console the database gave or the user chose
    public func game(console chosen: String? = nil) -> ConsoleGame? {
        guard let console = isRecognized ? console : chosen else { return nil }
        var game = ConsoleGame(console: console, name: name, databaseName: isRecognized ? databaseName : nil,
                               file: file, discs: discs, identifiedBy: isRecognized ? identifiedBy ?? .chosen : .chosen)
        game.crc = crc
        return game
    }
}

// Tells console game files apart against the libretro database: the CRC32 of a
// cartridge, the serial a PlayStation disc carries, then the SHA-1 of its data
// track, then the file name. It reads files and writes none.
public struct Identifier: Sendable {

    public let database: ContentDatabase
    public var consoles: [Console]

    public init(database: ContentDatabase, consoles: [Console] = ConsoleCatalog.all) {
        self.database = database
        self.consoles = consoles
    }

    // The files a drop or a folder holds that can be games: a disc's tracks
    // and the discs an .m3u lists go with their sheet, not on their own
    public static func files(in urls: [URL]) -> [URL] {
        let wanted = ConsoleCatalog.extensions.union(["zip"])
        var found: [URL] = []
        for url in urls {
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isFolder) else { continue }
            if isFolder.boolValue {
                let walker = FileManager.default.enumerator(
                    at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants])
                while let item = walker?.nextObject() as? URL {
                    if wanted.contains(item.pathExtension.lowercased()),
                       (try? item.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                        found.append(item.standardizedFileURL)
                    }
                }
            } else if wanted.contains(url.pathExtension.lowercased()) {
                found.append(url.standardizedFileURL)
            }
        }
        var covered = Set<String>()
        for file in found {
            switch file.pathExtension.lowercased() {
            case "m3u": covered.formUnion(Playlist.m3u(file).map { $0.path(percentEncoded: false) })
            case "cue": covered.formUnion(Playlist.cue(file).map { $0.path(percentEncoded: false) })
            default: break
            }
        }
        var seen = Set<String>()
        return found
            .filter { !covered.contains($0.path(percentEncoded: false)) }
            .filter { seen.insert($0.path(percentEncoded: false)).inserted }
            .sorted { $0.path(percentEncoded: false).localizedStandardCompare($1.path(percentEncoded: false)) == .orderedAscending }
    }

    public func identify(_ urls: [URL]) async -> [Identification] {
        var out: [Identification] = []
        for file in Self.files(in: urls) { out.append(await identify(file)) }
        return out
    }

    public func identify(_ file: URL) async -> Identification {
        let ext = file.pathExtension.lowercased()
        switch ext {
        case "m3u": return await identifySet(file)
        case "cue", "chd": return await identifyDisc(file)
        case "zip": return await identifyArchive(file)
        default: return await identifyCartridge(file, ext: ext)
        }
    }

    private func offered(_ ext: String) -> [Console] {
        ConsoleCatalog.consoles(forExtension: ext).filter { console in consoles.contains { $0.id == console.id } }
    }

    private func unknown(_ file: URL, ext: String) -> Identification {
        Identification(file: file, name: GameTitle.fromFile(file), candidates: offered(ext).map(\.id))
    }

    private func found(_ file: URL, _ entry: DatabaseEntry, _ console: Console, by: IdentifiedBy) -> Identification {
        Identification(file: file, console: console.id, databaseName: entry.name, name: GameTitle.display(entry.name),
                       identifiedBy: by, candidates: [console.id])
    }

    private func identifyCartridge(_ file: URL, ext: String) async -> Identification {
        let candidates = offered(ext)
        guard !candidates.isEmpty else { return unknown(file, ext: ext) }
        var sums: [UInt32] = []
        if let whole = try? CRC32.checksum(of: file) { sums.append(whole) }
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        // A copier's 512-byte header on a SNES cartridge, or iNES's 16 bytes
        if ext == "smc" || ext == "sfc", size % 1024 == 512, let bare = try? CRC32.checksum(of: file, skipping: 512) {
            sums.append(bare)
        }
        if ext == "nes", Self.head(file, 4) == Data("NES\u{1A}".utf8), let bare = try? CRC32.checksum(of: file, skipping: 16) {
            sums.append(bare)
        }
        for console in candidates {
            for crc in sums {
                if let entry = await database.match(crc: crc, in: console) {
                    var result = found(file, entry, console, by: .checksum)
                    result.crc = sums.first
                    return result
                }
            }
        }
        for console in candidates {
            if let entry = await database.match(name: GameTitle.fromFile(file), in: console) {
                var result = found(file, entry, console, by: .fileName)
                result.crc = sums.first
                return result
            }
        }
        var result = unknown(file, ext: ext)
        result.crc = sums.first
        return result
    }

    // The member of a zip that is a game; its CRC is in the zip's own directory
    private func identifyArchive(_ file: URL) async -> Identification {
        guard let member = Zip.members(file).first(where: { !offered(($0.name as NSString).pathExtension.lowercased()).isEmpty })
        else { return unknown(file, ext: "zip") }
        let ext = (member.name as NSString).pathExtension.lowercased()
        for console in offered(ext) {
            if let entry = await database.match(crc: member.crc, in: console) {
                var result = found(file, entry, console, by: .checksum)
                result.crc = member.crc
                return result
            }
        }
        var result = unknown(file, ext: ext)
        result.candidates = offered(ext).map(\.id)
        result.crc = member.crc
        return result
    }

    private func identifyDisc(_ file: URL) async -> Identification {
        let ext = file.pathExtension.lowercased()
        let candidates = offered(ext)
        if ext == "cue", let track = Playlist.cue(file).first {
            if let serial = DiscSerial.playStation(track) {
                for console in candidates {
                    if let entry = await database.match(serial: serial, in: console) { return found(file, entry, console, by: .discID) }
                }
            }
            if let sha1 = Self.sha1(track) {
                for console in candidates {
                    if let entry = await database.match(sha1: sha1, in: console) { return found(file, entry, console, by: .checksum) }
                }
            }
        }
        // A .chd is compressed by hunks; its name is what is read
        for console in candidates {
            if let entry = await database.match(name: GameTitle.fromFile(file), in: console) {
                return found(file, entry, console, by: .fileName)
            }
        }
        return unknown(file, ext: ext)
    }

    // One game for every disc an .m3u lists, known by its first disc
    private func identifySet(_ file: URL) async -> Identification {
        let discs = Playlist.m3u(file)
        guard let first = discs.first else { return unknown(file, ext: "m3u") }
        var result = await identifyDisc(first)
        result.file = file
        result.discs = discs
        if !result.isRecognized { result.name = GameTitle.fromFile(file) }
        return result
    }

    static func head(_ url: URL, _ count: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: count)
    }

    static func sha1(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = Insecure.SHA1()
        while let chunk = try? handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// The files a .cue or an .m3u names, next to it
public enum Playlist {
    public static func cue(_ url: URL) -> [URL] {
        guard let text = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .isoLatin1))
        else { return [] }
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            let line = line.trimmingCharacters(in: .whitespaces)
            guard line.uppercased().hasPrefix("FILE ") else { return nil }
            var rest = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            let name: String
            if rest.hasPrefix("\""), let end = rest.dropFirst().firstIndex(of: "\"") {
                name = String(rest[rest.index(after: rest.startIndex)..<end])
            } else {
                // FILE track.bin BINARY: the name ends at the last space
                if let space = rest.lastIndex(of: " ") { rest = String(rest[..<space]) }
                name = rest
            }
            return sibling(name, of: url)
        }
    }

    public static func m3u(_ url: URL) -> [URL] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            let line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
            return sibling(line, of: url)
        }
    }

    static func sibling(_ name: String, of url: URL) -> URL {
        name.hasPrefix("/") ? URL(fileURLWithPath: name).standardizedFileURL
            : url.deletingLastPathComponent().appending(path: name).standardizedFileURL
    }
}

// The product code a PlayStation disc carries in its first sectors, read as
// RetroArch's scanner reads it: SLUS_005.94 is SLUS-00594
public enum DiscSerial {
    static let prefixes = ["SCUS", "SLUS", "SLES", "SCED", "SLPS", "SLPM", "SCPS", "SLED", "SIPS", "ESPM", "SCES", "SLKA", "SCAJ"]

    public static func playStation(_ track: URL) -> String? {
        guard let data = Identifier.head(track, 60_000) else { return nil }
        return playStation(in: data)
    }

    public static func playStation(in data: Data) -> String? {
        let bytes = [UInt8](data)
        guard bytes.count > 12 else { return nil }
        for i in 0..<(bytes.count - 11) where bytes[i] == UInt8(ascii: "S") || bytes[i] == UInt8(ascii: "E") {
            let word = String(decoding: bytes[i..<(i + 4)], as: UTF8.self)
            guard prefixes.contains(word), bytes[i + 4] == UInt8(ascii: "_") else { continue }
            // NNN.NN or NNNN.N after the underscore
            let tail = String(decoding: bytes[(i + 5)..<(i + 11)], as: UTF8.self)
            let digits = tail.filter(\.isNumber)
            guard digits.count == 5, tail.filter({ $0 == "." }).count == 1 else { continue }
            return "\(word)-\(digits)"
        }
        return nil
    }
}

// The central directory of a zip: each member's name and CRC32, without unpacking
public enum Zip {
    public struct Member: Sendable, Equatable {
        public var name: String
        public var crc: UInt32
        public var size: UInt64
    }

    public static func members(_ url: URL) -> [Member] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return [] }
        let tailSize = min(end, 65_557)
        try? handle.seek(toOffset: end - tailSize)
        guard let tail = try? handle.read(upToCount: Int(tailSize)), tail.count >= 22 else { return [] }
        let bytes = [UInt8](tail)
        func le(_ b: [UInt8], _ at: Int, _ n: Int) -> UInt64 {
            (0..<n).reduce(0) { $0 | UInt64(b[at + $1]) << (8 * UInt64($1)) }
        }
        guard let eocd = stride(from: bytes.count - 22, through: 0, by: -1).first(where: {
            le(bytes, $0, 4) == 0x0605_4B50
        }) else { return [] }
        let count = Int(le(bytes, eocd + 10, 2))
        let size = Int(le(bytes, eocd + 12, 4))
        let offset = le(bytes, eocd + 16, 4)
        try? handle.seek(toOffset: offset)
        guard let directory = try? handle.read(upToCount: size) else { return [] }
        let dir = [UInt8](directory)
        var members: [Member] = []
        var at = 0
        for _ in 0..<count {
            guard at + 46 <= dir.count, le(dir, at, 4) == 0x0201_4B50 else { break }
            let nameLength = Int(le(dir, at + 28, 2)), extra = Int(le(dir, at + 30, 2)), comment = Int(le(dir, at + 32, 2))
            guard at + 46 + nameLength <= dir.count else { break }
            let name = String(decoding: dir[(at + 46)..<(at + 46 + nameLength)], as: UTF8.self)
            if !name.hasSuffix("/") {
                members.append(Member(name: name, crc: UInt32(le(dir, at + 16, 4)), size: le(dir, at + 24, 4)))
            }
            at += 46 + nameLength + extra + comment
        }
        return members
    }
}
