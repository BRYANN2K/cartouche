import AppKit
import Foundation
import RetroArchKit
import SwiftUI
import Testing

@testable import NotProtonApp

@Suite("The + menu", .serialized)
@MainActor
struct AddMenuTests {

    private static func game(_ source: GameSource, _ name: String) -> Game {
        Game(id: "\(source.id):\(name)", source: source, name: name, installed: true)
    }

    private func model(_ label: String) throws -> (LibraryModel, SteamFixture) {
        let fixture = try SteamFixture("add-menu-\(label)")
        return (libraryModel(fixture, defaults: ScratchDefaults()), fixture)
    }

    private func state(_ id: String, in items: [AddMenuItem]) -> AddMenuItem.State? {
        items.first { $0.id == id }?.state
    }

    private func item(_ id: String, _ state: AddMenuItem.State, name: String? = nil) -> AddMenuItem {
        AddMenuItem(id: id, name: name ?? id, badge: .text(id), state: state)
    }

    // MARK: Stores

    @Test("Fresh install: Steam is checked and dimmed, every other store can be added; EA is off")
    func freshInstall() async throws {
        let (model, fixture) = try model("fresh")
        defer { fixture.remove() }
        await model.load()
        let items = model.storeMenu(added: [])
        #expect(items.map(\.id) == ["steam", "epic", "gog", "amazon", "ubisoft"])
        #expect(state("steam", in: items) == .locked)
        #expect(items.dropFirst().allSatisfy { $0.state == .available })
        #expect(items.allSatisfy { $0.note == nil }, "EA was the only Experimental store")
    }

    @Test("One click checks the row, the menu stays open, and a second click undoes it")
    func addAndUndo() async throws {
        let (model, fixture) = try model("add")
        defer { fixture.remove() }
        await model.load()
        model.showAddStores = true
        model.addStore(.gog)
        #expect(model.showAddStores)
        #expect(state("gog", in: model.storeMenu(added: ["gog"])) == .added)
        #expect(model.sidebarSources.contains(.gog))

        model.unaddStore(.gog)
        #expect(!model.sidebarSources.contains(.gog))
        #expect(state("gog", in: model.storeMenu(added: ["gog"])) == .available)
    }

    @Test("Already added before the menu opened: checked and dimmed")
    func addedEarlier() async throws {
        let (model, fixture) = try model("earlier")
        defer { fixture.remove() }
        await model.load()
        model.addStore(.epic)
        #expect(state("epic", in: model.storeMenu(added: [])) == .locked)
    }

    @Test("A connected store, or one with games, cannot be un-added here, and right-click Remove stays")
    func cannotUnadd() async throws {
        let (model, fixture) = try model("locked")
        defer { fixture.remove() }
        await model.load()

        model.addStore(.epic)
        model.stores[.epic] = .connected(account: "fennec")
        #expect(state("epic", in: model.storeMenu(added: ["epic"])) == .locked)
        model.unaddStore(.epic)
        #expect(model.sidebarSources.contains(.epic))

        model.addStore(.gog)
        model.otherGames = [Self.game(.gog, "Witcher")]
        #expect(state("gog", in: model.storeMenu(added: ["gog"])) == .locked)
        model.unaddStore(.gog)
        #expect(model.sidebarSources.contains(.gog))

        #expect(model.canRemoveStore(.gog))
        model.removeStore(.gog)
        #expect(!model.sidebarSources.contains(.gog))
    }

    @Test("Nothing left: every row is locked, so the menu shows its one line")
    func nothingLeft() async throws {
        let (model, fixture) = try model("empty")
        defer { fixture.remove() }
        await model.load()
        for store in model.addableStores { model.addStore(store) }
        #expect(model.addableStores.isEmpty)
        #expect(model.storeMenu(added: []).isSettled)
        #expect(!model.storeMenu(added: ["ubisoft"]).isSettled)
    }

    // MARK: Consoles

    @Test("Consoles: the catalog by maker, BIOS and found games in the row's note")
    func consoles() async throws {
        let scene = try await ConsoleScene("menu")
        defer { scene.remove() }
        await scene.center.reload()
        scene.center.found = ["gb": 4, "gbc": 1]
        let items = scene.center.consoleMenu(added: [])
        #expect(items.map(\.id) == ConsoleMaker.allCases.flatMap { ConsoleCatalog.made(by: $0).map(\.id) })
        #expect(items.first?.group == ConsoleMaker.nintendo.title)
        #expect(items.last?.group == ConsoleMaker.others.title)
        #expect(items.allSatisfy { $0.state == .available })
        #expect(items.first { $0.id == "ps1" }?.note == String(localized: "Needs BIOS"))
        #expect(items.first { $0.id == "gb" }?.note == String(localized: "\(4) games"))
        #expect(items.first { $0.id == "gbc" }?.note == String(localized: "1 game"))
    }

    @Test("Adding a console downloads its core through the real flow, row busy, then checked; undo takes it back")
    func addConsole() async throws {
        let scene = try await ConsoleScene("add-menu")
        defer { scene.remove() }
        await scene.library.load()
        await scene.center.reload()

        scene.center.enqueueAdd("gb")
        scene.center.enqueueAdd("gb")
        #expect(state("gb", in: scene.center.consoleMenu(added: ["gb"])) == .pending)
        scene.center.enqueueAdd("gbc")
        await scene.center.addsFinished()

        #expect(scene.library.consoles == ["gb", "gbc"])
        #expect(scene.coreRequests == ["/nightly/sameboy_libretro.dylib.zip"])
        #expect(state("gb", in: scene.center.consoleMenu(added: ["gb"])) == .added)
        #expect(state("gb", in: scene.center.consoleMenu(added: [])) == .locked)

        await scene.center.unadd("gb")
        #expect(scene.library.consoles == ["gbc"])
        #expect(state("gb", in: scene.center.consoleMenu(added: ["gb"])) == .available)
        #expect(scene.coresFolder == ["sameboy_libretro.dylib"])
    }

    @Test("A console with games cannot be un-added here")
    func consoleWithGames() async throws {
        let scene = try await ConsoleScene("menu-games")
        defer { scene.remove() }
        await scene.center.reload()
        await scene.center.add(["gb"])
        let rom = scene.work.appending(path: "quest.gb")
        try ConsoleFixtures.homebrewGB(title: "QUEST").write(to: rom)
        await scene.center.addGames([ConsoleGame(console: "gb", name: "Quest", databaseName: nil, file: rom,
                                                 identifiedBy: .checksum)])
        #expect(!scene.center.games(of: "gb").isEmpty)
        #expect(state("gb", in: scene.center.consoleMenu(added: ["gb"])) == .locked)
        await scene.center.unadd("gb")
        #expect(scene.library.consoles == ["gb"])
    }

    // MARK: Keyboard

    @Test("Escape closes, from any row and from the one-line state")
    func escape() {
        let rows = [item("a", .available), item("b", .locked)]
        #expect(AddMenuKeyboard.action(.escape, cursor: nil, items: rows) == .close)
        #expect(AddMenuKeyboard.action(.escape, cursor: "a", items: rows) == .close)
        #expect(AddMenuKeyboard.action(.escape, cursor: nil, items: []) == .close)
    }

    @Test("Arrows, Home and End skip locked rows and wrap; Return and Space act on the row")
    func arrows() {
        let rows = [item("a", .locked), item("b", .available), item("c", .pending), item("d", .added)]
        #expect(AddMenuKeyboard.action(.downArrow, cursor: nil, items: rows) == .move("b"))
        #expect(AddMenuKeyboard.action(.upArrow, cursor: nil, items: rows) == .move("d"))
        #expect(AddMenuKeyboard.action(.downArrow, cursor: "b", items: rows) == .move("d"))
        #expect(AddMenuKeyboard.action(.downArrow, cursor: "d", items: rows) == .move("b"))
        #expect(AddMenuKeyboard.action(.home, cursor: "d", items: rows) == .move("b"))
        #expect(AddMenuKeyboard.action(.end, cursor: "b", items: rows) == .move("d"))
        #expect(AddMenuKeyboard.action(.return, cursor: "b", items: rows) == .toggle("b"))
        #expect(AddMenuKeyboard.action(.space, cursor: "d", items: rows) == .toggle("d"))
        #expect(AddMenuKeyboard.action(.return, cursor: nil, items: rows) == .none)
        #expect(AddMenuKeyboard.action(.return, cursor: "a", items: rows) == .none)
    }

    @Test("Escape, the arrows and Return map from their key codes, letters do not")
    func keyCodes() {
        #expect(AddMenuKeyboard.key(53) == .escape)
        #expect(AddMenuKeyboard.key(125) == .downArrow)
        #expect(AddMenuKeyboard.key(36) == .return)
        #expect(AddMenuKeyboard.key(0) == nil)
    }

    @Test("Typing jumps to the first row whose name starts with it")
    func typeahead() {
        let rows = [item("a", .locked, name: "Steam"), item("b", .available, name: "Sega Genesis"), item("c", .available, name: "Super Nintendo")]
        #expect(AddMenuKeyboard.match("s", items: rows) == "b")
        #expect(AddMenuKeyboard.match("su", items: rows) == "c")
        #expect(AddMenuKeyboard.match("x", items: rows) == nil)
    }

    // MARK: Marks and copy

    @Test("Every console has a template mark or a text mark, and Switch is text, never a logo")
    func marks() {
        for console in ConsoleCatalog.all {
            switch PlatformBadge.console(console.id) {
            case .mark(let mark):
                let image = PlatformMarkImage.image(mark)
                #expect(image != nil, "\(console.id)")
                #expect(image?.isTemplate == true, "\(console.id)")
            case .text(let text):
                #expect((2...4).contains(text.count), "\(console.id): \(text)")
            }
        }
        #expect(PlatformBadge.console("switch") == .text("NSW"))
        #expect(PlatformBadge.console("nes") == .text("NES"))
        #expect(PlatformBadge.console("xbox") == .mark(.xbox))
        #expect(PlatformBadge.console("ps2") == .mark(.playstation2))
        for store in GameSource.offered where store != .installer {
            #expect(PlatformBadge.source(store) != nil, "\(store)")
        }
    }

    @Test("Each language has the menu's copy, and French says stores")
    func strings() throws {
        let url = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/NotProtonApp/Resources/Localization/Localizable.xcstrings")
        let table = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let strings = try #require(table["strings"] as? [String: [String: Any]])
        func value(_ key: String, _ language: String) -> String? {
            let entry = strings[key]?["localizations"] as? [String: Any]
            let unit = (entry?[language] as? [String: Any])?["stringUnit"] as? [String: Any]
            return unit?["value"] as? String
        }
        for key in ["Add Stores", "Add Consoles", "All stores added", "All consoles added", "Add %@", "%@, added"] {
            for language in ["fr", "it", "zh-Hans"] { #expect(value(key, language) != nil, "\(key) \(language)") }
        }
        #expect(value("Add Stores", "fr") == "Ajouter des stores")
        #expect(value("All stores added", "fr") == "Tous les stores sont ajoutés")
        #expect(value("All consoles added", "fr") == "Toutes les consoles sont ajoutées")
        #expect(value("Needs BIOS", "fr") == "BIOS requis")
    }

    // MARK: Pictures

    private func shoot<V: View>(_ view: V, _ name: String, dark: Bool, folder: URL, size: CGSize) async throws {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.contentView = host
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.contentView = nil }
        try await Task.sleep(for: .seconds(0.5))
        let rep = try #require(renderedBitmap(host))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try #require(rep.representation(using: .png, properties: [:])).write(to: folder.appending(path: "\(name).png"))
    }

    // No Vision here: the PNGs are written straight from the bitmap and read by eye
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CARTOUCHE_ADD_MENU_SNAPSHOTS"] != nil))
    func snapshots() async throws {
        let folder = URL(filePath: ProcessInfo.processInfo.environment["CARTOUCHE_ADD_MENU_SNAPSHOTS"] ?? "/tmp")
        let scene = try await ConsoleScene("add-menu-shots")
        defer { scene.remove() }
        await scene.library.load()
        await scene.center.reload()
        scene.center.found = ["nes": 14, "n64": 6]
        scene.library.addStore(.gog)
        scene.library.addStore(.epic)
        scene.library.otherGames = [Self.game(.gog, "Witcher")]
        scene.library.selection = .all
        await scene.center.add(["snes", "gba", "ps2"])
        let shots = AppRefreshSnapshotTests()
        defer { shots.unpin() }
        for (language, dark) in [("en", false), ("en", true), ("fr", false), ("fr", true)] {
            shots.pin(language)
            let tone = "\(language)-\(dark ? "dark" : "light")"
            let locale = Locale(identifier: language)
            let stores = AddMenu.stores(scene.library).environment(\.locale, locale).background(Glass.window)
            try await shoot(stores, "stores-\(tone)", dark: dark, folder: folder, size: CGSize(width: 312, height: 300))
            let consoles = AddMenu.consoles(scene.center).environment(\.locale, locale).background(Glass.window)
            try await shoot(consoles, "consoles-\(tone)", dark: dark, folder: folder, size: CGSize(width: 312, height: 560))
            let sidebar = LibrarySidebar(model: scene.library).environment(scene.center).environment(\.locale, locale)
                .frame(width: 240, height: 460).background(Glass.window)
            try await shoot(sidebar, "sidebar-\(tone)", dark: dark, folder: folder, size: CGSize(width: 240, height: 460))
        }
    }
}
