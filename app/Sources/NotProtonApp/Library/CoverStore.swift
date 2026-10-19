// Where a game's cover comes from. The user's own image wins; then Steam's library
// art for the App ID, from Steam's own cache first, then Cartouche's copy of Steam's
// CDN art; then the store's art; and last a cover drawn from the name.

import Foundation
import RetroArchKit

enum CoverArt: Equatable, Sendable {
    case image(URL)
    // Drawn from the game's name and its executable icon
    case drawn
}

enum ArtKind: String, Sendable {
    // 600 by 900, the grid
    case cover = "library_600x900"
    // The wide picture at the top of the panel
    case hero = "library_hero"
}

struct CoverStore: Sendable {

    typealias Fetch = HTTPFetch.Fetch

    var steamCache: URL = SupportPaths.Steam.userData.appending(path: "appcache/librarycache")
    var cache: URL = SupportPaths.home.appending(path: "Library/Caches/\(SupportPaths.supportDirName)/covers")
    var fetch: Fetch = HTTPFetch.download(timeout: 15)
    // libretro-thumbnails for console games; nil uses the project's server
    var thumbnails: Thumbnails?

    var consoleThumbnails: Thumbnails {
        var chosen = thumbnails ?? Thumbnails(cache: cache.appending(path: "consoles", directoryHint: .isDirectory), fetch: fetch)
        chosen.base = QAEnvironment.url(chosen.base)
        return chosen
    }

    // Box art in the grid; a screenshot, else the title screen, else the box at the top of the panel
    static func thumbnailKinds(_ kind: ArtKind) -> [ThumbnailKind] {
        kind == .cover ? [.boxart] : [.snap, .title, .boxart]
    }

    private func consoleName(_ game: Game) -> (system: String, name: String)? {
        guard let console = game.console, let name = console.databaseName,
              let system = ConsoleCatalog.console(console.console)?.system else { return nil }
        return (system, name)
    }

    static func cdn(_ appID: Int, _ kind: ArtKind) -> URL {
        QAEnvironment.url(URL(string: "https://shared.fastly.steamstatic.com/store_item_assets/steam/apps/\(appID)/\(kind.rawValue).jpg")!)
    }

    // What is on disk now, without the network
    func local(for game: Game, kind: ArtKind, override: URL?) -> CoverArt? {
        if kind == .cover, let override, exists(override) { return .image(override) }
        if let appID = game.steamAppID {
            if let found = steamFile(appID, kind) { return .image(found) }
            let mine = cached(appID, kind)
            if exists(mine) { return .image(mine) }
        }
        if let store = storeFile(game), exists(store) { return .image(store) }
        if let (system, name) = consoleName(game) {
            // A picture not tried yet comes before a fallback already here
            for art in Self.thumbnailKinds(kind) {
                if let found = consoleThumbnails.local(system: system, kind: art, name: name) { return .image(found) }
                if !consoleThumbnails.isMissing(system: system, kind: art, name: name) { return nil }
            }
        }
        return nil
    }

    // The local art, or Steam's CDN copied into Cartouche's cache, or the drawn cover.
    // Offline, the CDN step fails and the next source is used.
    func art(for game: Game, kind: ArtKind, override: URL?) async -> CoverArt {
        if let found = local(for: game, kind: kind, override: override) { return found }
        if let appID = game.steamAppID, let saved = await download(appID, kind) { return .image(saved) }
        if let remote = game.artwork, let file = storeFile(game), let saved = await download(remote, to: file) { return .image(saved) }
        if let (system, name) = consoleName(game) {
            for art in Self.thumbnailKinds(kind) {
                if let saved = await consoleThumbnails.image(system: system, kind: art, name: name) { return .image(saved) }
            }
        }
        return .drawn
    }

    // Steam keeps library art as <appid>_library_600x900.jpg in older clients, and in
    // a folder per app, sometimes one level deeper, in newer ones
    func steamFile(_ appID: Int, _ kind: ArtKind) -> URL? {
        let names = kind == .cover ? ["library_600x900.jpg", "library_capsule.jpg"] : ["library_hero.jpg"]
        let flat = steamCache.appending(path: "\(appID)_\(kind.rawValue).jpg")
        if exists(flat) { return flat }
        let folder = steamCache.appending(path: String(appID))
        for name in names where exists(folder.appending(path: name)) { return folder.appending(path: name) }
        let inner = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for sub in inner.map(\.lastPathComponent).sorted() {
            let found = names.map { folder.appending(path: sub).appending(path: $0) }.first(where: exists)
            if let found { return found }
        }
        return nil
    }

    func cached(_ appID: Int, _ kind: ArtKind) -> URL {
        cache.appending(path: "\(appID)/\(kind.rawValue).jpg")
    }

    // A store game's art, one file for the grid and the panel
    func storeFile(_ game: Game) -> URL? {
        guard game.source.isStore, game.artwork != nil else { return nil }
        return cache.appending(path: "store/\(game.source.id)/\(StoreFolders.safe(game.id)).img")
    }

    private func download(_ appID: Int, _ kind: ArtKind) async -> URL? {
        await download(Self.cdn(appID, kind), to: cached(appID, kind))
    }

    private func download(_ url: URL, to file: URL) async -> URL? {
        // A recent failure is remembered: without it every redraw retries the
        // CDN for a cover that is not there
        let mark = file.appendingPathExtension("missing")
        if let date = (try? FileManager.default.attributesOfItem(
            atPath: mark.path(percentEncoded: false)))?[.modificationDate] as? Date,
           Date().timeIntervalSince(date) < Self.missingTTL { return nil }
        guard let (data, status) = try? await fetch(url), status == 200, Self.looksLikeImage(data) else {
            try? FileManager.default.createDirectory(at: mark.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data().write(to: mark)
            return nil
        }
        try? FileManager.default.removeItem(at: mark)
        do {
            try atomicReplace(file, with: data, step: "cover")
            return file
        } catch {
            return nil
        }
    }

    static let missingTTL: TimeInterval = 3600

    // JPEG or PNG, so an error page is never shown as a cover
    static func looksLikeImage(_ data: Data) -> Bool {
        data.starts(with: [0xFF, 0xD8, 0xFF]) || data.starts(with: [0x89, 0x50, 0x4E, 0x47])
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }
}
