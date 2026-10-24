import Foundation
import RetroArchKit
import Testing

@testable import NotProtonApp

@Suite("Automatic Switch artwork")
@MainActor
struct SwitchArtworkTests {
    private func game(_ name: String = "[Game] Hades [0100535012974000][US][v0]") -> Game {
        ConsoleCenter.libraryGame(ConsoleGame(console: "switch", name: name, databaseName: nil,
            file: URL(filePath: "/games/\(name).nsp"), identifiedBy: .chosen))
    }

    @Test("The filename's title ID resolves artwork without changing the game identity")
    func identification() throws {
        let hades = game()
        #expect(hades.name == "Hades")
        #expect(hades.id.contains("[0100535012974000]"))
        #expect(SwitchArtwork.titleID(hades) == "0100535012974000")
        #expect(SwitchArtwork.titleID(game("Hades [0100535012974000abcdef]")) == nil)
        #expect(SwitchArtwork.titleID(game("Hades [0100535012974000]")) != nil)
        #expect(SwitchArtwork.titleID(game("Hades")) == nil)
        var renamed = try #require(hades.console)
        renamed.name = "My Hades"
        #expect(ConsoleCenter.libraryGame(renamed).name == "My Hades")
    }

    @Test("Switch icons and banners are fetched automatically, cached offline, and overridden by a chosen image")
    func artwork() async throws {
        let work = try scratchDirectory("switch-artwork")
        defer { try? FileManager.default.removeItem(at: work) }
        let web = StubWeb()
        let icon = try ConsoleCoverTests.png(width: 128, height: 128)
        let banner = try ConsoleCoverTests.png(width: 256, height: 128)
        web.put("/nx/0100535012974000/icon", icon)
        web.put("/nx/0100535012974000/banner/720p", banner)
        let fetch = web.fetch, base = web.base
        let covers = CoverStore(steamCache: work.appending(path: "steam"), cache: work, fetch: { url in
            guard url.host == "api.nlib.cc" else { throw URLError(.unsupportedURL) }
            return try await fetch(base.appending(path: String(url.path.dropFirst())))
        })
        let hades = game()
        guard case .image(let file) = await covers.art(for: hades, kind: .cover, override: nil),
              case .image(let hero) = await covers.art(for: hades, kind: .hero, override: nil) else {
            Issue.record("Switch artwork was not resolved")
            return
        }
        #expect(try Data(contentsOf: file) == icon)
        #expect(try Data(contentsOf: hero) == banner)
        #expect(web.requests == ["/nx/0100535012974000/icon", "/nx/0100535012974000/banner/720p"])
        web.goOffline()
        #expect(await covers.art(for: hades, kind: .cover, override: nil) == .image(file))
        let chosen = work.appending(path: "chosen.png")
        try banner.write(to: chosen)
        #expect(await covers.art(for: hades, kind: .cover, override: chosen) == .image(chosen))
        #expect(web.requests.count == 2)
    }

    @Test("Console menus offer a local override without Steam search; PC menus retain Steam search")
    func menu() throws {
        let work = try scratchDirectory("switch-cover-menu")
        defer { try? FileManager.default.removeItem(at: work) }
        let model = LibraryModel(store: LibraryStore(folder: work), defaults: ScratchDefaults().defaults)
        let console = GameMenu.items(for: game(), in: model)
        #expect(console.contains { $0.action == .changeCover })
        #expect(!console.flatMap(\.children).contains { $0.action == .searchCover })
        let steam = GameMenu.items(for: Game.steam(1, name: "PC game", installed: false), in: model)
        #expect(steam.flatMap(\.children).contains { $0.action == .searchCover })
    }
}
