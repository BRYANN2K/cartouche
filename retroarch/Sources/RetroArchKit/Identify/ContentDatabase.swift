import Foundation

// Where each console's database file comes from: libretro-database, one .rdb per system. It names games and holds checksums; it holds no game.
public struct DatabaseSource: Sendable, Equatable {
    public var base: URL

    public init(base: URL) { self.base = base }

    public static let libretro = DatabaseSource(
        base: URL(string: "https://raw.githubusercontent.com/libretro/libretro-database/master/rdb/")!)

    public func url(for console: Console) -> URL {
        base.appending(path: "\(console.system).rdb")
    }
}

//// What a game is called in the library, from its database name: "Legend of Zelda, The - A Link to the Past (USA)"
//// reads "The Legend of Zelda: A Link to the Past"
public enum GameTitle {
    public static func display(_ databaseName: String) -> String {
        var name = databaseName
        // Region, languages, revision, disc and dump flags
        name = name.replacing(/\s*[\(\[][^\)\]]*[\)\]]/, with: "")
        name = name.trimmingCharacters(in: .whitespaces)
        if let match = name.firstMatch(of: /^(.+?), (The|A|An)( - |$)/) {
            name = "\(match.2) \(match.1)\(match.3)" + name[match.range.upperBound...]
        }
        if let dash = name.range(of: " - ") {
            name.replaceSubrange(dash, with: ": ")
        }
        return name
    }

    public static func fromFile(_ url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }
}

// The libretro database of each console, downloaded the first time a game of that console is identified, kept under Cartouche's RetroArch folder
public actor ContentDatabase {

    public typealias Fetch = @Sendable (URL) async throws -> (Data, Int)

    struct Index {
        var byCRC: [UInt32: [DatabaseEntry]] = [:]
        var bySerial: [String: [DatabaseEntry]] = [:]
        var bySHA1: [String: [DatabaseEntry]] = [:]
        var byName: [String: [DatabaseEntry]] = [:]

        init(_ entries: [DatabaseEntry]) {
            for entry in entries {
                if let crc = entry.crc { byCRC[crc, default: []].append(entry) }
                if let serial = entry.serial { bySerial[serial.uppercased(), default: []].append(entry) }
                if let sha1 = entry.sha1 { bySHA1[sha1, default: []].append(entry) }
                byName[entry.name.lowercased(), default: []].append(entry)
            }
        }
    }

    public let folder: URL
    public let source: DatabaseSource
    private let fetch: Fetch
    private var indexes: [String: Index] = [:]

    public init(paths: RetroArchPaths, source: DatabaseSource = .libretro, fetch: @escaping Fetch = ContentDatabase.download) {
        folder = paths.database
        self.source = source
        self.fetch = fetch
    }

    public func file(for console: Console) -> URL { folder.appending(path: "\(console.system).rdb") }

    public func isHere(_ console: Console) -> Bool {
        FileManager.default.fileExists(atPath: file(for: console).path(percentEncoded: false))
    }

    @discardableResult
    public func prepare(_ console: Console) async -> Bool {
        if indexes[console.id] != nil { return true }
        let local = file(for: console)
        if !isHere(console) {
            guard let (data, status) = try? await fetch(source.url(for: console)), status == 200,
                  (try? RDB.parse(data)) != nil
            else { return false }
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            guard (try? data.write(to: local, options: .atomic)) != nil else { return false }
        }
        guard let entries = try? RDB.read(local) else { return false }
        indexes[console.id] = Index(entries)
        return true
    }

    public func match(crc: UInt32, in console: Console) async -> DatabaseEntry? {
        guard await prepare(console) else { return nil }
        return Self.best(indexes[console.id]?.byCRC[crc])
    }

    // RetroArch reads PS1 serials as SLUS-00594; the database also lists them with a disc suffix, SLUS-00594-0
    public func match(serial: String, in console: Console) async -> DatabaseEntry? {
        guard await prepare(console), let index = indexes[console.id] else { return nil }
        let key = serial.uppercased()
        return Self.best(index.bySerial[key]) ?? Self.best(index.bySerial["\(key)-0"])
    }

    public func match(sha1: String, in console: Console) async -> DatabaseEntry? {
        guard await prepare(console) else { return nil }
        return Self.best(indexes[console.id]?.bySHA1[sha1.lowercased()])
    }

    public func match(name: String, in console: Console) async -> DatabaseEntry? {
        guard await prepare(console) else { return nil }
        return Self.best(indexes[console.id]?.byName[name.lowercased()])
    }

    // The verified dump first: no bracketed TOSEC flags, then the fullest row
    static func best(_ entries: [DatabaseEntry]?) -> DatabaseEntry? {
        entries?.min { a, b in
            if a.isFlagged != b.isFlagged { return !a.isFlagged }
            return (a.romName != nil ? 1 : 0) + (a.serial != nil ? 1 : 0) > (b.romName != nil ? 1 : 0) + (b.serial != nil ? 1 : 0)
        }
    }

    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config)
    }()

    @Sendable public static func download(_ url: URL) async throws -> (Data, Int) {
        let (data, response) = try await session.data(from: url)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}
