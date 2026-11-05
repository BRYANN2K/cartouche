// Cover order: the user's own image, Steam's library art (its cache first, then Cartouche's copy of the CDN art),
// the store's art, a Windows game's own exe icon on a generated background, then a cover drawn from the name.

import AppKit
import Foundation
import ImageIO
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
    var fetch: Fetch = HTTPFetch.download(timeout: 15, userAgent: "Cartouche/\(AppVersion.bundled)")
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
        guard let console = game.console, console.console != "switch", let name = console.databaseName,
              let system = ConsoleCatalog.console(console.console)?.system else { return nil }
        return (system, name)
    }

    static func cdn(_ appID: Int, _ kind: ArtKind) -> URL {
        QAEnvironment.url(URL(string: "https://shared.fastly.steamstatic.com/store_item_assets/steam/apps/\(appID)/\(kind.rawValue).jpg")!)
    }

    func local(for game: Game, kind: ArtKind, override: URL?) -> CoverArt? {
        if kind == .cover, let override, exists(override) { return .image(override) }
        if let id = SwitchArtwork.titleID(game) {
            let file = SwitchArtwork.cached(id, kind: kind, cache: cache)
            if exists(file) { return .image(file) }
        }
        if let appID = game.steamAppID {
            if let found = steamFile(appID, kind) { return .image(found) }
            let mine = cached(appID, kind)
            if exists(mine) { return .image(mine) }
        }
        if let store = storeFile(game, kind: kind), exists(store),
           kind != .cover || !betterCover(game) || Self.portrait(store) { return .image(store) }
        if kind == .hero, let cover = storeFile(game, kind: .cover), exists(cover), !Self.portrait(cover) {
            // A wide cover file still fills the panel better than nothing
            return .image(cover)
        }
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
        if let id = SwitchArtwork.titleID(game),
           let saved = await download(QAEnvironment.url(SwitchArtwork.url(id, kind: kind)),
                                      to: SwitchArtwork.cached(id, kind: kind, cache: cache)) {
            return .image(saved)
        }
        if let appID = game.steamAppID, let saved = await download(appID, kind) { return .image(saved) }
        // The panel takes the space's wide art; the card takes the portrait candidate
        let remote = kind == .cover ? game.artwork : (game.mediaHeader ?? game.artwork)
        if let remote, let file = storeFile(game, kind: kind), let saved = await download(remote, to: file) {
            if kind != .cover || game.artworkFallback == nil || Self.portrait(saved) { return .image(saved) }
            // A wide answer is not a cover: nothing kept unless it is the tile itself
            if remote != game.artworkFallback { try? FileManager.default.removeItem(at: saved) }
        }
        if kind == .cover, game.artworkFallback != nil {
            // The compat match's Steam cover, same file a Steam game's lands in
            if let appID = game.compatAppID {
                let mine = cached(appID, kind)
                if let found = steamFile(appID, kind) ?? (exists(mine) ? mine : nil), Self.portrait(found) {
                    return .image(found)
                }
                if let saved = await download(appID, kind), Self.portrait(saved) { return .image(saved) }
            }
            // PCGamingWiki's own jacket, fetched on demand — never bundled with the app
            if let file = storeFile(game, kind: kind), let saved = await wikiCover(game, to: file) {
                return .image(saved)
            }
            // Last resort: the launcher's own tile, kept even though it is wide
            if let remote = game.artworkFallback, let file = storeFile(game, kind: kind) {
                if exists(file) { return .image(file) }
                if let saved = await download(remote, to: file) { return .image(saved) }
            }
        }
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

    // True while a level above the tile could still answer for this cover: the game's
    // own candidate or the compat match's Steam art. Once only the tile is left, the
    // cached copy serves straight away.
    private func betterCover(_ game: Game) -> Bool {
        guard game.artworkFallback != nil else { return false }
        if let artwork = game.artwork, artwork != game.artworkFallback { return true }
        if game.compatAppID != nil { return true }
        // The public wiki could still know this title's jacket
        if let file = storeFile(game, kind: .cover), !exists(file.appendingPathExtension("wikimissing")) { return true }
        return false
    }

    func storeFile(_ game: Game, kind: ArtKind = .cover) -> URL? {
        guard game.source.isStore else { return nil }
        // The panel's wide art has its own file so it never lands in the cover's;
        // without one the hero shares the cover's file, as before
        let name = StoreFolders.safe(game.id) + (kind == .cover || game.mediaHeader == nil ? "" : "-\(kind.rawValue)")
        return cache.appending(path: "store/\(game.source.id)/\(name).img")
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
        let answer = try? await fetch(url)
        guard let (data, status) = answer, status == 200, Self.looksLikeImage(data) else {
            // Only an answer that there is no image is remembered; offline or a server error retries next time
            if let status = answer?.1, status == 404 || status == 410 || status == 200 {
                try? FileManager.default.createDirectory(at: mark.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? Data().write(to: mark)
            }
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

    // A card cover is a real jacket only when the downloaded image is taller than wide
    static func portrait(_ file: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return false }
        return height > width
    }

    // MARK: PCGamingWiki jacket — public MediaWiki API, no key (CC BY-NC-SA 3.0)

    // The title's jacket when the launchers and Steam have none: page wikitext names
    // the cover file, imageinfo resolves it, the image is cached in the store slot.
    // A wiki miss is remembered an hour so a redraw does not ask again.
    private func wikiCover(_ game: Game, to file: URL) async -> URL? {
        let mark = file.appendingPathExtension("wikimissing")
        if exists(mark), Date().timeIntervalSince(modified(mark)) < Self.missingTTL { return nil }
        var cover = await wikiCoverFile(game.name)
        if cover == nil, let found = await wikiSearchTitle(game.name) {
            cover = await wikiCoverFile(found)
        }
        guard let cover else { touch(mark); return nil }
        guard let info = try? await fetch(Self.wikiImageQuery(cover)), info.1 == 200,
              let remote = Self.wikiImageURL(info.0),
              let image = try? await fetch(remote), image.1 == 200, Self.looksLikeImage(image.0) else { return nil }
        do {
            try atomicReplace(file, with: image.0, step: "cover")
            if Self.portrait(file) { return file }
            try FileManager.default.removeItem(at: file)
        } catch { return nil }
        touch(mark)  // the wiki's only answer was not a jacket
        return nil
    }

    // The cover filename the page's infobox names, nil when the page has none or is missing.
    private func wikiCoverFile(_ title: String) async -> String? {
        guard let answer = try? await fetch(Self.wikiQuery(title)), answer.1 == 200 else { return nil }
        return Self.wikiCoverName(answer.0)
    }

    // The wiki's own search for a page the title alone did not land: only a result
    // still containing the game's own name is trusted — anything else could be art
    // for a different game.
    private func wikiSearchTitle(_ name: String) async -> String? {
        guard let answer = try? await fetch(Self.wikiSearchQuery(name)), answer.1 == 200,
              let root = try? JSONSerialization.jsonObject(with: answer.0) as? [String: Any],
              let hits = (root["query"] as? [String: Any])?["search"] as? [[String: Any]] else { return nil }
        return hits.lazy.compactMap { $0["title"] as? String }
            .first { $0.range(of: name, options: .caseInsensitive) != nil }
    }

    static func wikiQuery(_ title: String) -> URL {
        var query = URLComponents(string: "https://www.pcgamingwiki.com/w/api.php")!
        query.queryItems = [
            .init(name: "action", value: "parse"), .init(name: "page", value: title),
            .init(name: "prop", value: "wikitext"), .init(name: "section", value: "0"),
            .init(name: "format", value: "json"),
        ]
        return QAEnvironment.url(query.url!)
    }

    static func wikiSearchQuery(_ name: String) -> URL {
        var query = URLComponents(string: "https://www.pcgamingwiki.com/w/api.php")!
        query.queryItems = [
            .init(name: "action", value: "query"), .init(name: "list", value: "search"),
            .init(name: "srsearch", value: "intitle:\"\(name)\""), .init(name: "srlimit", value: "1"),
            .init(name: "format", value: "json"),
        ]
        return QAEnvironment.url(query.url!)
    }

    static func wikiImageQuery(_ file: String) -> URL {
        var query = URLComponents(string: "https://www.pcgamingwiki.com/w/api.php")!
        query.queryItems = [
            .init(name: "action", value: "query"), .init(name: "titles", value: "File:" + file),
            .init(name: "prop", value: "imageinfo"), .init(name: "iiprop", value: "url"),
            .init(name: "format", value: "json"),
        ]
        return QAEnvironment.url(query.url!)
    }

    // `|cover = <file>` in the page's first section — the infobox's own jacket.
    static func wikiCoverName(_ body: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let text = ((root["parse"] as? [String: Any])?["wikitext"] as? [String: Any])?["*"] as? String else { return nil }
        for line in text.split(separator: "\n") where line.hasPrefix("|cover") {
            let name = line.drop(while: { $0 != "=" }).dropFirst()
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "File:", with: "")
            return name.isEmpty ? nil : name
        }
        return nil
    }

    static func wikiImageURL(_ body: Data) -> URL? {
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let page = ((root["query"] as? [String: Any])?["pages"] as? [String: Any])?.values.first as? [String: Any],
              let url = ((page["imageinfo"] as? [[String: Any]])?.first)?["url"] as? String else { return nil }
        return URL(string: url)
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }
}
