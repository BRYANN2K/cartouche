import AppKit
import SwiftUI
import Testing

@testable import NotProtonApp

@MainActor
@Suite("Toolbar balls", .serialized)
struct ToolbarBallsTests {
    private func card(_ game: Game, blocked: Bool = false, unknown: Bool = false) -> GameCard {
        GameCard(game: game, isSelected: false, isFavorite: false, override: nil, onSelect: {}, onFavorite: {},
                 onDropCover: { _ in }, menu: { [] }, perform: { _ in },
                 antiCheatBlocked: blocked, antiCheatUnknown: unknown)
    }

    private func width(_ model: LibraryModel) -> CGFloat {
        let host = NSHostingView(rootView: HStack(spacing: 12) { LibraryToolbarControls(model: model) })
        return host.fittingSize.width
    }

    @Test("An unidentified game's card shows the lock its launch already enforces")
    func unidentifiedCardLock() throws {
        let scene = try LibrarySortTests.Scene("card-lock")
        defer { scene.fixture.remove() }
        let unknown = Game(id: "ubisoft:4865", source: .ubisoft, name: "Ubisoft game 4865", installed: false)
        #expect(scene.model.launchProfile(for: unknown).protected)
        #expect(scene.model.antiCheatUnknown(unknown))
        let shown = card(unknown, unknown: scene.model.antiCheatUnknown(unknown))
        #expect(shown.lockedStatus == String(localized: "Anti-cheat"))
    }

    @Test("The lock stays off a named Ubisoft game and any other store, and Unsupported still wins")
    func cardLockScope() throws {
        let scene = try LibrarySortTests.Scene("card-lock-scope")
        defer { scene.fixture.remove() }
        scene.model.antiCheat = { $0.compatAppID == 359550 ? "BattlEye" : nil }
        var siege = Game(id: "ubisoft:635", source: .ubisoft, name: "Matched", installed: false)
        siege.compatAppID = 359550
        #expect(!scene.model.antiCheatUnknown(siege))
        #expect(card(siege).lockedStatus == nil)
        let epic = Game(id: "epic:1", source: .epic, name: "Clean", installed: false)
        #expect(!scene.model.antiCheatUnknown(epic))
        #expect(card(epic, unknown: scene.model.antiCheatUnknown(epic)).lockedStatus == nil)
        #expect(card(siege, blocked: true, unknown: true).lockedStatus == String(localized: "Anti-cheat unsupported"))
    }

    @Test("Each page gets its way out: launcher when signed in, the Steam client, or the store's site")
    func storeLinks() async throws {
        let scene = try await StoreScene("store-link")
        defer { scene.remove() }
        let center: StoreCenter = scene.center
        #expect(StoreLink.page(.source(.steam), stores: center) == .client(.steam))
        #expect(StoreLink.page(.source(.steam), stores: nil) == .client(.steam))
        let sites: [(GameSource, String)] = [(.epic, "https://store.epicgames.com"), (.gog, "https://www.gog.com"),
                                             (.amazon, "https://gaming.amazon.com")]
        for (store, site) in sites {
            #expect(StoreLink.page(.source(store), stores: center) == .web(store, try #require(URL(string: site))))
        }
        #expect(StoreLink.page(.source(.ubisoft), stores: center) == nil)
        try scene.seedUbisoft()
        await scene.signIn(.ubisoft, code: "00000000-dead-beef-0000-000000000042")
        #expect(StoreLink.page(.source(.ubisoft), stores: center) == .launcher(.ubisoft))
        for item: SidebarItem in [.all, .favorites, .source(.installer), .source(.console("ps1"))] {
            #expect(StoreLink.page(item, stores: center) == nil, "\(item)")
        }
    }

    @Test("Every store ball and sidebar row has a real logo")
    func marks() {
        for store in GameSource.pc where store != .installer {
            let mark = PlatformMark.source(store)
            #expect(mark != nil, "\(store)")
            if let mark { #expect(PlatformMarkImage.image(mark) != nil, "\(store)") }
        }
    }

    @Test("The sort ball's tooltip says the sort and the filter")
    func summary() throws {
        let plain = LibrarySortBall.summary(sort: .playTime, installedOnly: false)
        #expect(plain == String(localized: "Sort · \(LibrarySort.playTime.title)"))
        let filtered = LibrarySortBall.summary(sort: .playTime, installedOnly: true)
        #expect(filtered.hasPrefix(plain))
        #expect(filtered.hasSuffix(String(localized: "library.filter.installed", defaultValue: "Installed")))
    }

    @Test("At the window's smallest width the title gives way, so the controls stay out of the overflow")
    func titleWidth() {
        #expect(WindowLayout(width: 800, sidebar: true).title == 232)
        #expect(WindowLayout(width: 1280, sidebar: true).title == 656)
    }

    @Test("The round controls match the + and show where the bar showed")
    func rounds() throws {
        let scene = try LibrarySortTests.Scene("round-controls", steam: LibrarySortTests.mixed,
                                               other: [LibrarySortTests.game("Fortnite", .epic)])
        defer { scene.fixture.remove() }
        scene.model.stores = [.epic: .connected(account: "player42")]
        #expect(abs(width(scene.model) - 32) < 0.01, "All Games: the sort ball alone")
        scene.model.selection = .source(.steam)
        #expect(abs(width(scene.model) - (32 * 2 + 12)) < 0.01, "A store page adds its ball")
        scene.model.installedOnly = true
        #expect(abs(width(scene.model) - (32 * 2 + 12)) < 0.01, "The filter changes the fill, not the size")
        scene.model.installedOnly = false
        scene.model.selection = .favorites
        #expect(!scene.model.screen.showsLibraryControls)
        #expect(width(scene.model) == 0)
    }
}
