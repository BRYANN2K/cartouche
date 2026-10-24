// Owned games come from the export the running Steam client writes to steam-library.json; closed, the last export still speaks, however old. Steam's own files give installed games, play data and collections.

import Foundation

// The export file, as the Steam side writes it. Version 1.
struct SteamExport: Codable, Equatable, Sendable {
    struct App: Codable, Equatable, Sendable {
        let appid: Int
        let name: String
        let installed: Bool
        let lastPlayed: Int?
        let playtime: Int?
        let hidden: Bool?

        enum CodingKeys: String, CodingKey {
            case appid, name, installed, lastPlayed = "last_played", playtime, hidden
        }
    }

    struct Collection: Codable, Equatable, Sendable {
        let id: String
        let name: String
        let apps: [Int]
    }

    let version: Int
    let generated: Int
    let steamid: String
    let apps: [App]
    let collections: [Collection]?

    static let fileName = "steam-library.json"

    static func read(_ url: URL) -> SteamExport? {
        guard let data = try? Data(contentsOf: url),
              let export = try? JSONDecoder().decode(SteamExport.self, from: data),
              export.version == 1
        else { return nil }
        return export
    }
}

enum SteamPresence: Equatable, Sendable {
    case notInstalled
    case closed
    case running
}

struct SteamImport: Equatable, Sendable {
    var presence: SteamPresence
    var account: SteamAccount?
    var games: [Game]
    // When the export the list comes from was written, nil when it comes from Steam's files only
    var exported: Date?
}

struct SteamLibraryImporter: Sendable {

    var files = SteamLocalFiles()
    var export: URL = SupportPaths.support.appending(path: SteamExport.fileName)
    var isInstalled: @Sendable () -> Bool = { SteamBundle.isPresent }
    var isRunning: @Sendable () -> Bool = { SteamBundle.isRunning }

    func load() -> SteamImport {
        guard isInstalled() else {
            return SteamImport(presence: .notInstalled, account: nil, games: [], exported: nil)
        }
        let running = isRunning()
        let account = files.account()
        // An export from another account on this Mac is not this library
        let saved = SteamExport.read(export).flatMap { e in
            account == nil || e.steamid.isEmpty || e.steamid == account?.steamID ? e : nil
        }
        let installed = Dictionary(files.installed().map { ($0.appID, $0) }, uniquingKeysWith: { a, _ in a })
        let manifests = Set(files.manifests().map(\.appID))
        let play = account.map(files.playData) ?? [:]

        var games: [Int: Game] = [:]
        for app in saved?.apps ?? [] where !SteamLocalFiles.isTool(appID: app.appid, name: app.name) {
            // Closed, the export may be old, so Steam's manifests say what is installed
            let isInstalled = running
                ? app.installed && (!manifests.contains(app.appid) || installed[app.appid] != nil)
                : installed[app.appid] != nil
            var game = Game.steam(app.appid, name: app.name, installed: isInstalled)
            game.storageBytes = installed[app.appid]?.sizeOnDisk
            game.lastPlayed = SteamLocalFiles.date(app.lastPlayed)
            game.playtimeMinutes = app.playtime ?? 0
            games[app.appid] = game
        }
        for app in installed.values where games[app.appID] == nil {
            var game = Game.steam(app.appID, name: app.name, installed: true)
            game.storageBytes = app.sizeOnDisk
            game.lastPlayed = app.lastPlayed
            games[app.appID] = game
        }
        for (appID, data) in play {
            guard var game = games[appID] else { continue }
            game.lastPlayed = [game.lastPlayed, data.lastPlayed].compactMap { $0 }.max()
            game.playtimeMinutes = max(game.playtimeMinutes, data.playtimeMinutes)
            games[appID] = game
        }

        let collections = saved?.collections?.map { SteamCollection(id: $0.id, name: $0.name, apps: $0.apps) }
            ?? account.map(files.collections) ?? []
        for collection in collections {
            for appID in collection.apps where games[appID] != nil {
                games[appID]?.collections.append(collection.name)
            }
        }

        let list = games.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return SteamImport(
            presence: running ? .running : .closed, account: account, games: list,
            exported: saved.map { Date(timeIntervalSince1970: TimeInterval($0.generated)) })
    }

    // When the export last changed, so the library reloads within seconds of a new one
    func exportStamp() -> Date? {
        // Not URL resource values, which a URL caches after the first read
        (try? FileManager.default.attributesOfItem(atPath: export.path(percentEncoded: false)))?[.modificationDate] as? Date
    }
}
