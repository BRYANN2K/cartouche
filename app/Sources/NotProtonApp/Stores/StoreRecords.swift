// What Cartouche keeps about store games, under stores/ in its data folder:
//   stores/<store>/client      the client's own config and caches (tokens only while it runs)
//   stores/<store>/home        the HOME the client runs with
//   stores/<store>/library.json the account's games, so the library shows them offline
//   stores/<store>/games/<id>.json an installed game
//   stores/<store>/<slug>/pfx  its Wine prefix; game/ holds files Cartouche downloaded
// Nothing here is a token.

import Foundation

struct StoreInstalledGame: Codable, Sendable, Equatable {
    var store: String
    var id: String
    var title: String
    var install: StoreInstall
    // stores/<store>/<slug>
    var folder: URL
    // The store's markers of the last cloud save sync, per save location
    var saveStamps: [String: String] = [:]
    var installedAt: Date
    // Installed by another launcher and imported: uninstalling leaves the files alone
    var imported = false

    var source: GameSource? { GameSource(id: store) }
    var gameID: String { "\(store):\(id)" }
    var prefix: URL { folder.appending(path: "pfx", directoryHint: .isDirectory) }
}

struct StoreFolders: Sendable {
    let root: URL

    func store(_ source: GameSource) -> URL { root.appending(path: source.id, directoryHint: .isDirectory) }
    func client(_ source: GameSource) -> URL { store(source).appending(path: "client", directoryHint: .isDirectory) }
    func home(_ source: GameSource) -> URL { store(source).appending(path: "home", directoryHint: .isDirectory) }
    var temporary: URL { root.appending(path: "tmp", directoryHint: .isDirectory) }
    var clients: URL { root.appending(path: "clients", directoryHint: .isDirectory) }
    func library(_ source: GameSource) -> URL { store(source).appending(path: "library.json") }
    func records(_ source: GameSource) -> URL { store(source).appending(path: "games", directoryHint: .isDirectory) }
    func record(_ source: GameSource, id: String) -> URL { records(source).appending(path: "\(Self.safe(id)).json") }
    func gameFolder(_ source: GameSource, title: String, id: String) -> URL {
        store(source).appending(path: "\(GameFolder.slug(title))-\(Self.safe(id))", directoryHint: .isDirectory)
    }

    // Store IDs are letters, digits and dashes; anything else becomes a dash
    static func safe(_ id: String) -> String {
        String(id.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") ? $0 : "-" })
    }

    // Where the clients keep their tokens: legendary and nile in their config, gogdl
    // and comet in a heroic folder under their HOME
    func tokenFolder(_ source: GameSource) -> URL { source == .gog ? home(source) : client(source) }

    static let tokenPatterns: [GameSource: [String]] = [
        .epic: EpicAdapter.tokenFiles, .gog: GOGAdapter.tokenFiles, .amazon: AmazonAdapter.tokenFiles,
    ]

    func secrets(vault: any TokenVault) -> StoreSecrets {
        let stores: [GameSource] = [.epic, .gog, .amazon]
        return StoreSecrets(vault: vault, folders: Dictionary(uniqueKeysWithValues: stores.map { ($0, tokenFolder($0)) }),
                            patterns: Self.tokenPatterns)
    }

    func context(_ source: GameSource, files: StoreClientFiles, secrets: StoreSecrets) -> ClientContext {
        var context = ClientContext(files: files, secrets: secrets, folder: client(source), home: home(source), temporary: temporary)
        switch source {
        case .epic: context.extra = ["LEGENDARY_CONFIG_PATH": client(source).path(percentEncoded: false)]
        case .gog: context.extra = ["GOGDL_CONFIG_PATH": client(source).path(percentEncoded: false)]
        case .amazon: context.extra = ["NILE_CONFIG_PATH": client(source).path(percentEncoded: false)]
        default: break
        }
        return context
    }

    // MARK: Files

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    func loadLibrary(_ source: GameSource) -> [StoreGame] {
        (try? Data(contentsOf: library(source))).flatMap { try? Self.decoder.decode([StoreGame].self, from: $0) } ?? []
    }

    func saveLibrary(_ games: [StoreGame], for source: GameSource) throws {
        try atomicReplace(library(source), with: try Self.encoder.encode(games), step: String(localized: "Save the library"))
    }

    func loadRecords(_ source: GameSource) -> [StoreInstalledGame] {
        let files = (try? FileManager.default.contentsOfDirectory(at: records(source), includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }.compactMap {
            (try? Data(contentsOf: $0)).flatMap { try? Self.decoder.decode(StoreInstalledGame.self, from: $0) }
        }
    }

    func save(_ record: StoreInstalledGame) throws {
        guard let source = record.source else { return }
        try atomicReplace(self.record(source, id: record.id), with: try Self.encoder.encode(record), step: String(localized: "Save the game"))
    }

    func remove(_ record: StoreInstalledGame) {
        guard let source = record.source else { return }
        try? FileManager.default.removeItem(at: self.record(source, id: record.id))
    }
}
