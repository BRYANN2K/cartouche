// One adapter per store, over its client: sign in on the store's own page, list
// the games the account owns, install, update, verify, launch, uninstall, import
// and cloud saves. Adapters only read the clients' output and the files the
// games carry; the library, the runner and the prefix are StoreCenter's.

import Foundation

// What a store page says works, from what the pinned client can do
struct StoreCapabilities: Equatable, Sendable {

    enum Online: Equatable, Sendable {
        case dependsOnGame
        case throughComet
        case notSupported
    }

    // "legendary", "gogdl and comet", "nile"
    let client: String
    let downloads: Bool
    let cloudSaves: Bool
    let online: Online

    var cloudSavesLabel: String { cloudSaves ? String(localized: "Supported") : String(localized: "Not supported yet") }

    var onlineLabel: String {
        switch online {
        case .dependsOnGame: String(localized: "Depends on the game")
        case .throughComet: String(localized: "Achievements and friends, through comet")
        case .notSupported: String(localized: "Not supported yet")
        }
    }
}

// The store's own page, and what the sign-in window watches for once the user is done
struct SignInPage: Sendable, Equatable {
    let url: URL
    // Epic shows the code as the text of this one page; GOG and Amazon put it in the address
    let codePage: URL?

    var codeInPage: Bool { codePage != nil }

    // The only page whose text the sign-in window reads
    func isCodePage(_ url: URL) -> Bool {
        guard let codePage else { return false }
        return url.scheme == "https" && url.host() == codePage.host() && url.path() == codePage.path()
    }
}

// A game the account owns, as the store lists it
struct StoreGame: Codable, Sendable, Equatable, Identifiable {
    let id: String
    var title: String
    var art: URL?
    // Cloud saves for this game, when the store says
    var cloudSaves: Bool = false
}

// Where an installed game's files are, as the client reports them
struct StoreInstall: Codable, Sendable, Equatable {
    var path: URL
    var version: String?
}

// What starts the game, inside Wine: the exe, its arguments and folder
struct StoreLaunch: Sendable, Equatable {
    var executable: URL
    var arguments: [String]
    var workingDirectory: URL
    var environment: [String: String] = [:]
}

// A cloud save folder of a game, and the name the store keeps it under
struct SaveLocation: Codable, Sendable, Equatable {
    var name: String
    var path: URL
}

enum StoreError: LocalizedError, Equatable {
    // The store no longer accepts the saved token
    case sessionExpired
    case notSignedIn
    case failed(String)
    case unknownGame(String)

    var errorDescription: String? {
        switch self {
        case .sessionExpired: String(localized: "Your session expired. Sign in again.")
        case .notSignedIn: String(localized: "Sign in first.")
        case .failed(let message): message
        case .unknownGame(let name): String(localized: "Cartouche couldn’t tell which game is in “\(name)”.")
        }
    }
}

protocol StoreAdapter: Sendable {
    var store: GameSource { get }
    var capabilities: StoreCapabilities { get }

    func signInPage() async throws -> SignInPage
    // The code the page handed over, from the address the window reached or the page's text
    func code(at url: URL, pageText: String?) -> String?
    // Exchanges the code for tokens, through the client; returns the account name
    func finishSignIn(code: String) async throws -> String
    func signOut() async throws
    // Whether the saved tokens are already past their end, without asking the store
    func isExpired(_ secret: StoreSecret, now: Date) -> Bool

    func library() async throws -> [StoreGame]
    func install(_ game: StoreGame, base: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> StoreInstall
    func update(_ id: String, install: StoreInstall, progress: @escaping @Sendable (Double) -> Void) async throws -> StoreInstall
    func verify(_ id: String, install: StoreInstall, progress: @escaping @Sendable (Double) -> Void) async throws
    func uninstall(_ id: String, install: StoreInstall) async throws
    // A folder another launcher installed: the game it holds, registered with the client
    func importGame(at folder: URL, library: [StoreGame]) async throws -> (StoreGame, StoreInstall)

    // offline: the session expired or the Mac is offline; games that allow it still start
    func launch(_ id: String, install: StoreInstall, prefix: URL, offline: Bool) async throws -> StoreLaunch
    func saveLocations(_ id: String, install: StoreInstall, prefix: URL) async throws -> [SaveLocation]
    // direction: .download before the game starts, .upload after it quits. stamps are
    // the store's own markers of the last sync, per location, returned updated.
    func syncSaves(_ id: String, locations: [SaveLocation], direction: SaveDirection, stamps: [String: String]) async throws -> [String: String]

    // Box art, when the library list does not carry it
    func artURL(_ game: StoreGame) async -> URL?
    // A program that runs beside the game, as comet does for GOG's online features
    func companion(_ id: String) async throws -> ClientCommand?
}

extension StoreAdapter {
    func artURL(_ game: StoreGame) async -> URL? { game.art }
    func companion(_ id: String) async throws -> ClientCommand? { nil }
}

enum SaveDirection: Sendable { case download, upload }

// The client of a store, run with its own folder for config and tokens, a
// private HOME and temporary folder, and no other variable from the app
struct ClientContext: Sendable {
    let files: StoreClientFiles
    let secrets: StoreSecrets
    // stores/<store>/client: the client's config, library cache and tokens
    let folder: URL
    let home: URL
    let temporary: URL
    var extra: [String: String] = [:]

    var environment: [String: String] {
        var env = ["HOME": home.path(percentEncoded: false), "TMPDIR": temporary.path(percentEncoded: false),
                   "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8"]
        env.merge(extra) { $1 }
        return env
    }

    func run(_ client: StoreClient, store: GameSource, _ arguments: [String], account: String? = nil,
             onLine: @escaping @Sendable (String) -> Void = { _ in }) async throws -> ClientOutput {
        let executable = try await files.ensure(client)
        for dir in [folder, home, temporary] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let command = ClientCommand(executable: executable, arguments: arguments, environment: environment)
        return try await secrets.using(store, account: account) {
            try await ClientProcess.run(command, onLine: onLine)
        }
    }
}

enum StoreJSON {
    static func object(_ text: String) -> [String: Any]? {
        lastJSON(text) as? [String: Any]
    }

    static func array(_ text: String) -> [Any]? {
        lastJSON(text) as? [Any]
    }

    // Clients print log lines around their JSON; the JSON is the last line that parses
    static func lastJSON(_ text: String) -> Any? {
        if let whole = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]),
           whole is [Any] || whole is [String: Any] { return whole }
        for line in text.split(whereSeparator: \.isNewline).reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("{") || trimmed.hasPrefix("[") else { continue }
            if let value = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) { return value }
        }
        return nil
    }
}

extension URL {
    // A folder as the clients take it: no trailing slash, which they would double
    var clientPath: String {
        let path = path(percentEncoded: false)
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}

// Windows paths a game names, inside its prefix
enum PrefixPaths {
    static let user = "crossover"

    static func user(_ prefix: URL) -> URL {
        let users = prefix.appending(path: "drive_c/users")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: users.path(percentEncoded: false))) ?? []
        let name = names.filter { $0 != "Public" && !$0.hasPrefix(".") }.sorted().first ?? user
        return users.appending(path: name)
    }

    static func documents(_ prefix: URL) -> URL { user(prefix).appending(path: "Documents") }
    static func savedGames(_ prefix: URL) -> URL { user(prefix).appending(path: "Saved Games") }
    static func localAppData(_ prefix: URL) -> URL { user(prefix).appending(path: "AppData/Local") }
    static func roamingAppData(_ prefix: URL) -> URL { user(prefix).appending(path: "AppData/Roaming") }

    // Joins a path written with backslashes or slashes under a folder, never above it
    static func join(_ base: URL, _ relative: String) -> URL {
        let parts = relative.replacingOccurrences(of: "\\", with: "/").split(separator: "/")
            .filter { $0 != "." && $0 != ".." && !$0.isEmpty }
        return parts.reduce(base) { $0.appending(path: String($1)) }
    }
}
