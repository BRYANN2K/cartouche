import Foundation
import SwiftUI
import Testing

@testable import NotProtonApp

@Suite("Covers for PC games")
struct CoverTests {

    private static let elden = Game.steam(1_245_620, name: "Elden Ring", installed: true)

    @Test("Steam's own library cache comes first, in each layout Steam has used")
    func steamCacheLayouts() throws {
        let fixture = try SteamFixture("cache")
        defer { fixture.remove() }
        let covers = fixture.covers()
        let cache = fixture.steam.appending(path: "appcache/librarycache")
        #expect(covers.local(for: Self.elden, kind: .cover, override: nil) == nil)

        // Older clients: one flat file per app
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try SteamFixture.png("A", size: CGSize(width: 6, height: 9), hue: 0).write(to: cache.appending(path: "730_library_600x900.jpg"))
        #expect(covers.local(for: .steam(730, name: "CS2", installed: true), kind: .cover, override: nil)
            == .image(cache.appending(path: "730_library_600x900.jpg")))

        let nested = cache.appending(path: "367520/4f1c2a")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try SteamFixture.png("B", size: CGSize(width: 6, height: 9), hue: 0).write(to: nested.appending(path: "library_600x900.jpg"))
        #expect(covers.local(for: .steam(367_520, name: "HK", installed: true), kind: .cover, override: nil)
            == .image(nested.appending(path: "library_600x900.jpg")))

        try fixture.addArt([1_245_620])
        #expect(covers.local(for: Self.elden, kind: .cover, override: nil)
            == .image(cache.appending(path: "1245620/library_600x900.jpg")))
        #expect(covers.local(for: Self.elden, kind: .hero, override: nil)
            == .image(cache.appending(path: "1245620/library_hero.jpg")))
    }

    @Test("Steam game offline: a cover shown once comes from Cartouche's cache")
    func offlineFromCache() async throws {
        let fixture = try SteamFixture("offline")
        defer { fixture.remove() }
        let art = try SteamFixture.png("Elden Ring", size: CGSize(width: 60, height: 90), hue: 0.1)
        let asked = Box<[URL]>([])
        let online = fixture.covers { url in asked.value.append(url); return (art, 200) }
        #expect(await online.art(for: Self.elden, kind: .cover, override: nil) == .image(fixture.caches.appending(path: "1245620/library_600x900.jpg")))
        #expect(asked.value == [URL(string: "https://shared.fastly.steamstatic.com/store_item_assets/steam/apps/1245620/library_600x900.jpg")!])

        // The Mac goes offline: every request fails, the cover still shows
        let offline = fixture.covers()
        #expect(offline.local(for: Self.elden, kind: .cover, override: nil) == .image(fixture.caches.appending(path: "1245620/library_600x900.jpg")))
        #expect(await offline.art(for: Self.elden, kind: .cover, override: nil) == .image(fixture.caches.appending(path: "1245620/library_600x900.jpg")))
    }

    @Test("Nothing found: the cover is drawn from the name, never a broken image")
    func nothingFound() async throws {
        let fixture = try SteamFixture("drawn")
        defer { fixture.remove() }
        // Offline, a 404, and an error page served as 200 all end on the drawn cover
        let fetches: [CoverStore.Fetch] = [
            { @Sendable _ in throw URLError(.notConnectedToInternet) },
            { @Sendable _ in (Data(), 404) },
            { @Sendable _ in (Data("<html>error</html>".utf8), 200) },
        ]
        for fetch in fetches {
            #expect(await fixture.covers(fetch: fetch).art(for: Self.elden, kind: .cover, override: nil) == .drawn)
        }
        let installer = Game(id: "installer:x", source: .installer, name: "Some Game", installed: true)
        #expect(await fixture.covers().art(for: installer, kind: .cover, override: nil) == .drawn)
        // No image is kept (a .missing marker beside it only remembers the 404)
        #expect(!FileManager.default.fileExists(atPath: fixture.caches.appending(path: "1245620/library_600x900.jpg").path))
    }

    @Test("Offline or a server error is retried on the next draw; only a 404 or a non-image is remembered as missing")
    func missingOnlyWhenAnswered() async throws {
        let fixture = try SteamFixture("missing-mark")
        defer { fixture.remove() }
        let art = try SteamFixture.png("Elden Ring", size: CGSize(width: 60, height: 90), hue: 0.1)
        let mark = fixture.caches.appending(path: "1245620/library_600x900.jpg.missing")
        let failures: [CoverStore.Fetch] = [
            { @Sendable _ in throw URLError(.notConnectedToInternet) },
            { @Sendable _ in (Data(), 503) },
        ]
        for failing in failures {
            #expect(await fixture.covers(fetch: failing).download(1_245_620, .cover) == nil)
            #expect(!FileManager.default.fileExists(atPath: mark.path(percentEncoded: false)))
        }
        #expect(await fixture.covers { _ in (art, 200) }.download(1_245_620, .cover) != nil)

        let other = Game.steam(730, name: "CS2", installed: true)
        let asked = Box<Int>(0)
        let gone = fixture.covers { _ in asked.value += 1; return (Data(), 404) }
        #expect(await gone.download(730, .cover) == nil)
        #expect(await gone.art(for: other, kind: .cover, override: nil) == .drawn)
        #expect(asked.value == 1)
    }

    @Test("User override: a dropped image wins from then on, and survives a library refresh")
    @MainActor
    func userOverride() async throws {
        let fixture = try SteamFixture("override")
        defer { fixture.remove() }
        try fixture.writeExport()
        try fixture.addArt([1_245_620])
        let scratch = ScratchDefaults()
        let model = libraryModel(fixture, defaults: scratch)
        await model.load()

        let dropped = fixture.root.appending(path: "my-cover.png")
        try SteamFixture.png("Mine", size: CGSize(width: 60, height: 90), hue: 0.6).write(to: dropped)
        model.setCover(dropped, for: "steam:1245620")
        let kept = try #require(model.coverOverride(for: "steam:1245620"))
        #expect(kept.deletingLastPathComponent().lastPathComponent == "covers")
        #expect(kept.path.hasPrefix(fixture.support.path))
        // The original can go; Cartouche keeps its own copy
        try FileManager.default.removeItem(at: dropped)
        #expect(fixture.covers().local(for: Self.elden, kind: .cover, override: kept) == .image(kept))

        await model.load()
        let relaunched = libraryModel(fixture, defaults: scratch)
        await relaunched.load()
        #expect(relaunched.coverOverride(for: "steam:1245620") == kept)
        #expect(fixture.covers().local(for: Self.elden, kind: .cover, override: relaunched.coverOverride(for: "steam:1245620")) == .image(kept))

        relaunched.clearCover(for: "steam:1245620")
        #expect(fixture.covers().local(for: Self.elden, kind: .cover, override: relaunched.coverOverride(for: "steam:1245620"))
            == .image(fixture.steam.appending(path: "appcache/librarycache/1245620/library_600x900.jpg")))
    }

    @Test("Only images are kept from the CDN")
    func imageCheck() {
        #expect(CoverStore.looksLikeImage(Data([0xFF, 0xD8, 0xFF, 0xE0])))
        #expect(CoverStore.looksLikeImage(Data([0x89, 0x50, 0x4E, 0x47, 0x0D])))
        #expect(!CoverStore.looksLikeImage(Data("<html>".utf8)))
    }

    @Test("The drawn cover renders the name in light and dark")
    @MainActor
    func drawnRenders() {
        let game = Game(id: "installer:x", source: .installer, name: "Kingdom Come: Deliverance", installed: true)
        for dark in [false, true] {
            let size = snapshot(DrawnCover(game: game).frame(width: 200, height: 300), named: "cover-drawn", dark: dark)
            #expect(size.height >= 300)
        }
    }
}
