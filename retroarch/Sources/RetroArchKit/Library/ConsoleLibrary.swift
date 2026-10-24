import Foundation

public enum ConsoleLook: String, Codable, Sendable, CaseIterable, Identifiable {
    case original, crt, lcd

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .original: String(localized: "Original", bundle: .module)
        case .crt: "CRT"
        case .lcd: "LCD"
        }
    }
}

public struct ConsoleGameSetup: Codable, Sendable, Equatable {
    // nil plays with the console's recommended core
    public var core: String?
    public var look: ConsoleLook = .original
    // RetroArch's run-ahead, one frame
    public var lowerInputLag = true
    public var hardcore = false
    public var disc = 0

    public init() {}
}

public enum IdentifiedBy: String, Codable, Sendable {
    // CRC32 of a cartridge, or of a disc track, in the libretro database
    case checksum
    // The serial a disc carries, in the libretro database
    case discID
    case fileName
    case chosen
}

public struct ConsoleGame: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var console: String
    public var name: String
    // The database's full name, which libretro-thumbnails files are named after
    public var databaseName: String?
    // What RetroArch loads: the cartridge, the .cue, or the .m3u of a multi-disc game
    public var file: String
    public var discs: [String] = []
    public var identifiedBy: IdentifiedBy
    public var added: Date
    public var lastPlayed: Date?
    public var playSeconds: Double = 0
    // The file's CRC32 as identification read it; netplay room matching reuses it
    public var crc: UInt32?
    public var setup = ConsoleGameSetup()

    public init(
        console: String, name: String, databaseName: String?, file: URL, discs: [URL] = [],
        identifiedBy: IdentifiedBy, added: Date = Date()
    ) {
        self.console = console
        self.name = name
        self.databaseName = databaseName
        self.file = file.path(percentEncoded: false)
        self.discs = discs.map { $0.path(percentEncoded: false) }
        self.identifiedBy = identifiedBy
        self.added = added
        id = Self.id(console: console, databaseName: databaseName, file: file)
    }

    public static func id(console: String, databaseName: String?, file: URL) -> String {
        "console:\(console):" + (databaseName ?? "file:\(file.lastPathComponent)")
    }

    public var fileURL: URL { URL(fileURLWithPath: file) }
    public var discURLs: [URL] { discs.map { URL(fileURLWithPath: $0) } }

    public var isMultiDisc: Bool { discs.count > 1 }

    // RetroArch names states and saves after the loaded file, without its extension
    public var contentName: String { fileURL.deletingPathExtension().lastPathComponent }

    public var exists: Bool { FileManager.default.fileExists(atPath: file) }
}

public actor ConsoleLibrary {

    public let file: URL
    private var cached: [ConsoleGame]?

    public init(paths: RetroArchPaths) {
        file = paths.root.appending(path: "library.json")
    }

    public func games() -> [ConsoleGame] {
        if let cached { return cached }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let loaded = (try? Data(contentsOf: file)).flatMap { try? decoder.decode([ConsoleGame].self, from: $0) } ?? []
        cached = loaded
        return loaded
    }

    public func game(_ id: String) -> ConsoleGame? { games().first { $0.id == id } }

    @discardableResult
    public func add(_ new: [ConsoleGame]) throws -> [ConsoleGame] {
        var all = games()
        var added: [ConsoleGame] = []
        for game in new where !all.contains(where: { $0.id == game.id }) {
            all.append(game)
            added.append(game)
        }
        if !added.isEmpty { try save(all) }
        return added
    }

    public func update(_ id: String, _ change: @Sendable (inout ConsoleGame) -> Void) throws {
        var all = games()
        guard let i = all.firstIndex(where: { $0.id == id }) else { return }
        change(&all[i])
        try save(all)
    }

    public func remove(_ id: String) throws {
        try save(games().filter { $0.id != id })
    }

    public func knownFiles() -> Set<String> {
        Set(games().flatMap { [$0.file] + $0.discs })
    }

    private func save(_ games: [ConsoleGame]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(games).write(to: file, options: .atomic)
        cached = games
    }
}
