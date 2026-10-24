import AppKit
import Foundation
import RetroArchKit
import SwiftUI
import Testing

@testable import NotProtonApp

@Suite("Console covers", .serialized)
@MainActor
struct ConsoleCoverTests {

    static let system = "Nintendo - Super Nintendo Entertainment System"
    static let name = "Legend of Zelda, The - A Link to the Past (USA)"

    private func game(file: URL = URL(fileURLWithPath: "/nonexistent/zelda.sfc")) -> Game {
        let console = ConsoleGame(console: "snes", name: GameTitle.display(Self.name), databaseName: Self.name,
                                  file: file, identifiedBy: .checksum)
        return ConsoleCenter.libraryGame(console)
    }

    static func png(width: Int, height: Int, colour: NSColor = .systemRed) throws -> Data {
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        colour.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    private func store(_ web: StubWeb, cache: URL) -> CoverStore {
        var thumbnails = Thumbnails(cache: cache.appending(path: "consoles"), fetch: web.fetch)
        thumbnails.base = web.base
        var covers = CoverStore(steamCache: cache.appending(path: "no-steam"), cache: cache, fetch: web.fetch)
        covers.thumbnails = thumbnails
        return covers
    }

    @Test("Covers come from libretro-thumbnails by database name, escaped, then show offline from the cache")
    func offlineAfterFirstView() async throws {
        let work = try scratchDirectory("console-covers")
        defer { try? FileManager.default.removeItem(at: work) }
        let web = StubWeb()
        let box = try Self.png(width: 256, height: 180), snap = try Self.png(width: 256, height: 224, colour: .systemBlue)
        let escaped = "Nintendo%20-%20Super%20Nintendo%20Entertainment%20System"
        let file = "Legend%20of%20Zelda%2C%20The%20-%20A%20Link%20to%20the%20Past%20%28USA%29.png"
        web.put("/\(escaped)/Named_Boxarts/\(file)", box)
        web.put("/\(escaped)/Named_Snaps/\(file)", snap)
        let rom = work.appending(path: "zelda.sfc")
        try ConsoleFixtures.homebrewSNES().write(to: rom)
        let game = game(file: rom)
        let covers = store(web, cache: work)

        #expect(covers.local(for: game, kind: .cover, override: nil) == nil)
        guard case .image(let cover) = await covers.art(for: game, kind: .cover, override: nil) else {
            Issue.record("no cover")
            return
        }
        guard case .image(let hero) = await covers.art(for: game, kind: .hero, override: nil) else {
            Issue.record("no screenshot")
            return
        }
        #expect(try Data(contentsOf: cover) == box)
        #expect(try Data(contentsOf: hero) == snap)
        #expect(web.requests == ["/\(escaped)/Named_Boxarts/\(file)", "/\(escaped)/Named_Snaps/\(file)"])
        print("evidence: requested \(web.requests)")

        // The Mac goes offline; the same covers show, from the cache
        web.goOffline()
        let later = store(web, cache: work)
        #expect(later.local(for: game, kind: .cover, override: nil) == .image(cover))
        #expect(await later.art(for: game, kind: .cover, override: nil) == .image(cover))
        #expect(await later.art(for: game, kind: .hero, override: nil) == .image(hero))
        #expect(web.requests.count == 2)

        // Drawn in the grid offline, the cover is the cached picture
        let card = UIHost(GameCard(game: game, isSelected: false, isFavorite: false, override: nil, onSelect: {}, onFavorite: {},
                                   onDropCover: { _ in }, menu: { [] }, perform: { _ in })
            .environment(\.covers, later).frame(width: 200).padding(), size: CGSize(width: 240, height: 300))
        defer { card.close() }
        await card.settle(0.6)
        let texts = try card.texts(named: "console-card-offline")
        #expect(seen(texts, "The Legend of Zelda"))
        let bitmap = try card.bitmap()
        let middle = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh * 2 / 5))
        #expect(middle.redComponent > 0.7 && middle.blueComponent < 0.4, "the cover is not the cached red box: \(middle)")
    }

    @Test("Square cards hold landscape and portrait boxes whole")
    func squareCards() async throws {
        let work = try scratchDirectory("console-square")
        defer { try? FileManager.default.removeItem(at: work) }
        #expect(game().coverShape == .square)
        for (label, width, height) in [("landscape", 300, 150), ("portrait", 150, 300)] {
            let picture = work.appending(path: "\(label).png")
            try Self.png(width: width, height: height).write(to: picture)
            let host = UIHost(CoverView(game: game(), override: picture).aspectRatio(1, contentMode: .fit).frame(width: 200, height: 200)
                .ignoresSafeArea(),
                              size: CGSize(width: 200, height: 200))
            await host.settle(0.4)
            let bitmap = try host.bitmap()
            _ = try host.texts(named: "console-square-\(label)")
            host.close()
            let scale = bitmap.pixelsWide / 200
            let top = 0
            func isRed(_ x: Int, _ y: Int) -> Bool {
                guard let c = bitmap.colorAt(x: x * scale, y: top + y * scale) else { return false }
                return c.redComponent > 0.7 && c.greenComponent < 0.4
            }
            // The whole picture shows; the square's rest is plain
            #expect(isRed(100, 100))
            if label == "landscape" {
                #expect(isRed(15, 100) && isRed(185, 100))
                #expect(!isRed(100, 10) && !isRed(100, 190))
            } else {
                #expect(isRed(100, 15) && isRed(100, 185))
                #expect(!isRed(10, 100) && !isRed(190, 100))
            }
        }
    }
}
