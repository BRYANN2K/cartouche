// Cover order: the user's own image, Steam's library art (its cache first, then Cartouche's copy of the CDN art),
// the store's art, a Windows game's own exe icon on a generated background, then a cover drawn from the name.

import AppKit
import Foundation
import RetroArchKit

enum CoverArt: Equatable, Sendable {
    case image(URL)
    case drawn
}

enum ArtKind: String, Sendable {
    case cover = "library_600x900"
    case hero = "library_hero"
}

struct CoverStore: Sendable {

    typealias Fetch = HTTPFetch.Fetch

    var steamCache: URL = SupportPaths.Steam.userData.appending(path: "appcache/librarycache")
    var cache: URL = SupportPaths.home.appending(path: "Library/Caches/\(SupportPaths.supportDirName)/covers")
    var fetch: Fetch = HTTPFetch.download(timeout: 15)
    // libretro-thumbnails for console games; nil uses the project's server
    var thumbnails: Thumbnails?
    // The exe icon for a placeholder cover (iconmaker through PlaceholderCover); overridable in tests
    var exeIcon: @Sendable (URL, URL) -> NSImage? = { exe, folder in
        PlaceholderCover.icon(exe, into: folder).flatMap { NSImage(contentsOf: $0) }
    }

    var consoleThumbnails: Thumbnails {
        var chosen = thumbnails ?? Thumbnails(cache: cache.appending(path: "consoles", directoryHint: .isDirectory), fetch: fetch)
        chosen.base = QAEnvironment.url(chosen.base)
        return chosen
    }

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

    func local(for game: Game, kind: ArtKind, override: URL?) -> CoverArt? {
        if kind == .cover, let override, exists(override) { return .image(override) }
        if let appID = game.steamAppID {
            if let found = steamFile(appID, kind) { return .image(found) }
            let mine = cached(appID, kind)
            if exists(mine) { return .image(mine) }
        }
        if let store = storeFile(game), exists(store) { return .image(store) }
        if let (system, name) = consoleName(game) {
            for art in Self.thumbnailKinds(kind) {
                if let found = consoleThumbnails.local(system: system, kind: art, name: name) { return .image(found) }
                if !consoleThumbnails.isMissing(system: system, kind: art, name: name) { return nil }
            }
        }
        if let file = placeholderFile(game, kind: kind), exists(file) { return .image(file) }
        return nil
    }

    // The local art, or Steam's CDN copied into Cartouche's cache, or the drawn cover. Offline, the CDN step fails and the next source is used.
    func art(for game: Game, kind: ArtKind, override: URL?) async -> CoverArt {
        if let found = local(for: game, kind: kind, override: override) { return found }
        if let appID = game.steamAppID, let saved = await download(appID, kind) { return .image(saved) }
        if let remote = game.artwork, let file = storeFile(game), let saved = await download(remote, to: file) { return .image(saved) }
        if let (system, name) = consoleName(game) {
            for art in Self.thumbnailKinds(kind) {
                if let saved = await consoleThumbnails.image(system: system, kind: art, name: name) { return .image(saved) }
            }
        }
        if let file = placeholder(game, kind: kind) { return .image(file) }
        return .drawn
    }

    // MARK: Exe-icon placeholder

    // Only Windows installer games: consoles are out of scope, stores and Steam
    // have their own art or a drawn cover.
    private func placeholderFile(_ game: Game, kind: ArtKind) -> URL? {
        guard game.source == .installer, let exe = game.executable else { return nil }
        let name = Digest.sha256(of: Data(exe.path(percentEncoded: false).utf8)).prefix(16)
        return cache.appending(path: "placeholders/\(name)-\(kind.rawValue).png")
    }

    private func placeholder(_ game: Game, kind: ArtKind) -> URL? {
        guard let exe = game.executable, let file = placeholderFile(game, kind: kind), exists(exe) else { return nil }
        let mark = file.appendingPathExtension("missing")
        if fresh(mark) { return nil }
        if exists(file), modified(file) >= modified(exe) { return file }
        guard let image = exeIcon(exe, file.deletingLastPathComponent()),
              let data = PlaceholderCover.png(name: game.name, icon: image, size: PlaceholderCover.size(kind)) else {
            touch(mark)
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

    static let placeholderMissingTTL: TimeInterval = 86400

    // A recent "no icon" is remembered: without it every redraw reruns iconmaker on an exe that has none
    private func fresh(_ mark: URL) -> Bool {
        Date().timeIntervalSince(modified(mark)) < Self.placeholderMissingTTL
    }

    private func modified(_ url: URL) -> Date {
        ((try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false)))?[.modificationDate] as? Date)
            ?? .distantPast
    }

    private func touch(_ url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data().write(to: url)
    }

    // Steam keeps library art as <appid>_library_600x900.jpg in older clients, and in a folder per app, sometimes one level deeper, in newer ones
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

    func storeFile(_ game: Game) -> URL? {
        guard game.source.isStore, game.artwork != nil else { return nil }
        return cache.appending(path: "store/\(game.source.id)/\(StoreFolders.safe(game.id)).img")
    }

    func download(_ appID: Int, _ kind: ArtKind) async -> URL? {
        await download(Self.cdn(appID, kind), to: cached(appID, kind))
    }

    private func download(_ url: URL, to file: URL) async -> URL? {
        // A recent failure is remembered: without it every redraw retries the CDN for a cover that is not there
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

    static func looksLikeImage(_ data: Data) -> Bool {
        data.starts(with: [0xFF, 0xD8, 0xFF]) || data.starts(with: [0x89, 0x50, 0x4E, 0x47])
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }
}
