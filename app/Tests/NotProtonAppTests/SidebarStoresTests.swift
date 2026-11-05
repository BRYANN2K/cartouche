import AppKit
import SwiftUI
import Testing

@testable import NotProtonApp

@Suite("Stores in the sidebar", .serialized)
@MainActor
struct SidebarStoresTests {

    private static func game(_ source: GameSource, _ name: String) -> Game {
        Game(id: "\(source.id):\(name)", source: source, name: name, installed: true)
    }

    private func model(_ label: String) throws -> (LibraryModel, SteamFixture, ScratchDefaults) {
        let fixture = try SteamFixture("sidebar-stores-\(label)")
        let scratch = ScratchDefaults()
        return (libraryModel(fixture, defaults: scratch), fixture, scratch)
    }

    @Test("Fresh install: Steam alone, every other store behind the +, EA off")
    func freshInstall() async throws {
        let (model, fixture, _) = try model("fresh")
        defer { fixture.remove() }
        await model.load()
        #expect(model.sidebarSources == [.steam])
        #expect(model.addableStores == [.epic, .gog, .amazon, .ubisoft])
        #expect(!model.addableStores.contains { $0.isExperimental })
        #expect(CouchNavigator.lists(model).allSatisfy { item in
            if case .source(let source) = item { return !source.isStore }
            return true
        })
    }

    @Test("Picking a store adds it, selects it and lands on its sign-in page")
    func addStore() async throws {
        let (model, fixture, _) = try model("add")
        defer { fixture.remove() }
        await model.load()
        model.addStore(.gog)
        #expect(model.sidebarSources == [.steam, .gog])
        #expect(model.selection == .source(.gog))
        #expect(model.screen == .signIn(.gog))
        #expect(!model.addableStores.contains(.gog))
        #expect(CouchNavigator.lists(model).contains(.source(.gog)))
    }

    @Test("Steam from the welcome page is selected and nothing is recorded")
    func addSteam() async throws {
        let (model, fixture, scratch) = try model("steam")
        defer { fixture.remove() }
        model.addStore(.steam)
        #expect(model.selection == .source(.steam))
        #expect(scratch.defaults.object(forKey: LibraryModel.sidebarStoresKey) == nil)
    }

    @Test("The choice survives a relaunch, and an id it no longer knows is dropped")
    func persistence() async throws {
        let (model, fixture, scratch) = try model("persist")
        defer { fixture.remove() }
        model.addStore(.epic)
        model.addStore(.ubisoft)
        model.removeStore(.ubisoft)

        var saved = try #require(scratch.defaults.dictionary(forKey: LibraryModel.sidebarStoresKey))
        saved["console:nes"] = true
        saved["gone"] = true
        scratch.defaults.set(saved, forKey: LibraryModel.sidebarStoresKey)

        let relaunched = libraryModel(fixture, defaults: scratch)
        await relaunched.load()
        #expect(relaunched.sidebarSources == [.steam, .epic])
        #expect(relaunched.addableStores.contains(.ubisoft))
    }

    @Test("Update: a store connected before this version stays, with its games, and offers no Remove")
    func migrationConnected() async throws {
        let scene = try await StoreScene("sidebar-migration")
        defer { scene.remove() }
        await scene.signIn(.epic, code: "epic-good-code")
        #expect(scene.defaults.defaults.object(forKey: LibraryModel.sidebarStoresKey) == nil)
        #expect(scene.model.isSignedIn(.source(.epic)))

        let updated = scene.makeCenter(folders: scene.folders, vault: scene.vault, library: scene.model)
        await updated.start(refresh: false)
        #expect(scene.model.sidebarSources.contains(.epic))
        #expect(!scene.model.addableStores.contains(.epic))
        #expect(!scene.model.canRemoveStore(.epic))
        let games = scene.model.games(in: .all).filter { $0.source == .epic }
        #expect(!games.isEmpty)
        #expect(scene.model.games(in: .source(.epic)) == games)
        scene.model.removeStore(.epic)
        #expect(scene.model.sidebarSources.contains(.epic))
    }

    @Test("Update: an expired store stays too, and a store in the middle of signing in keeps its row")
    func migrationExpired() async throws {
        let (model, fixture, _) = try model("expired")
        defer { fixture.remove() }
        model.stores[.epic] = .expired(account: "fennec")
        model.stores[.gog] = .waiting
        #expect(model.sidebarSources == [.steam, .epic, .gog])
        #expect(!model.canRemoveStore(.epic))
        #expect(!model.canRemoveStore(.gog))
    }

    @Test("Signing in from Settings shows the store and lands on it, whatever its place in the list")
    func signInFromSettings() async throws {
        let scene = try await StoreScene("sidebar-settings", gogServer: true)
        defer { scene.remove() }
        await scene.signIn(.gog, code: "gog-good-code")
        #expect(scene.model.sidebarSources.contains(.gog))
        #expect(scene.model.selection == .source(.gog))
    }

    @Test("Signing out of a store nobody added and with no games leaves the sidebar and its page")
    func signOutLeaves() async throws {
        let (model, fixture, _) = try model("signout")
        defer { fixture.remove() }
        model.stores[.epic] = .connected(account: "fennec")
        model.selection = .source(.epic)
        model.stores[.epic] = .notConnected
        #expect(model.sidebarSources == [.steam])
        #expect(model.selection == .all)
    }

    @Test("Signing out of an added store keeps it, ready to sign back in")
    func signOutKeepsAdded() async throws {
        let (model, fixture, _) = try model("signout-added")
        defer { fixture.remove() }
        model.addStore(.epic)
        model.stores[.epic] = .connected(account: "fennec")
        #expect(!model.canRemoveStore(.epic))
        model.stores[.epic] = .notConnected
        #expect(model.sidebarSources == [.steam, .epic])
        #expect(model.selection == .source(.epic))
        #expect(model.canRemoveStore(.epic))
    }

    @Test("Remove hides an unconnected store, sends the selection home and frees it for the +")
    func removeStore() async throws {
        let (model, fixture, _) = try model("remove")
        defer { fixture.remove() }
        await model.load()
        model.addStore(.amazon)
        #expect(model.canRemoveStore(.amazon))
        model.removeStore(.amazon)
        #expect(model.sidebarSources == [.steam])
        #expect(model.selection == .all)
        #expect(model.addableStores.contains(.amazon))
    }

    @Test("Steam and Windows Installers never offer Remove")
    func notRemovable() throws {
        let (model, fixture, _) = try model("fixed")
        defer { fixture.remove() }
        model.otherGames = [Self.game(.installer, "Setup")]
        #expect(!model.canRemoveStore(.steam))
        #expect(!model.canRemoveStore(.installer))
    }

    @Test("A store with games left after a sign-out shows, and Remove still hides it")
    func cachedGames() throws {
        let (model, fixture, _) = try model("cached")
        defer { fixture.remove() }
        model.otherGames = [Self.game(.gog, "Witcher")]
        #expect(model.sidebarSources == [.steam, .gog])
        #expect(model.canRemoveStore(.gog))
        model.removeStore(.gog)
        #expect(model.sidebarSources == [.steam])
        model.addStore(.gog)
        #expect(model.sidebarSources == [.steam, .gog])
    }

    @Test("A removed store that connects comes back, and its games stay in All Games")
    func removedThenConnected() async throws {
        let (model, fixture, _) = try model("removed-connected")
        defer { fixture.remove() }
        await model.load()
        model.otherGames = [Self.game(.gog, "Witcher")]
        model.removeStore(.gog)
        model.stores[.gog] = .connected(account: "fennec")
        #expect(model.sidebarSources.contains(.gog))
        #expect(model.games(in: .all).contains { $0.source == .gog })
    }

    @Test("Windows Installers shows from its first game and leaves with its last")
    func installers() throws {
        let (model, fixture, _) = try model("installers")
        defer { fixture.remove() }
        #expect(!model.sidebarSources.contains(.installer))
        model.otherGames = [Self.game(.installer, "Setup")]
        #expect(model.sidebarSources == [.steam, .installer])
        model.selection = .source(.installer)
        model.otherGames = []
        #expect(model.sidebarSources == [.steam])
        #expect(model.selection == .all)
    }

    @Test("A hidden store's row does not change the games All Games lists")
    func allGames() async throws {
        let (model, fixture, _) = try model("all-games")
        defer { fixture.remove() }
        await model.load()
        let steam = model.games(in: .all).count
        model.stores[.epic] = .connected(account: "fennec")
        model.otherGames = [Self.game(.epic, "Fennec")]
        #expect(model.games(in: .all).count == steam + 1)
        #expect(model.sidebarSources.contains(.epic))
    }

    @Test("Every store added: nothing left to add")
    func plusEmpties() throws {
        let (model, fixture, _) = try model("plus")
        defer { fixture.remove() }
        for store in model.addableStores { model.addStore(store) }
        #expect(model.addableStores.isEmpty)
        #expect(model.sidebarSources == GameSource.offered.filter { $0 != .installer })
    }

    @Test("Every language has the menu's title")
    func strings() throws {
        let url = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/NotProtonApp/Resources/Localization/Localizable.xcstrings")
        let table = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let strings = try #require(table["strings"] as? [String: [String: Any]])
        let entry = try #require(strings["Add Stores"]?["localizations"] as? [String: Any])
        #expect(Set(entry.keys) == ["fr", "it", "zh-Hans"])
    }

    // No Vision here: the PNGs are written straight from the bitmap and read by eye
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CARTOUCHE_SIDEBAR_STORES_SNAPSHOTS"] != nil))
    func snapshots() async throws {
        let folder = URL(filePath: ProcessInfo.processInfo.environment["CARTOUCHE_SIDEBAR_STORES_SNAPSHOTS"] ?? "/tmp")
        let scene = try await StoreScene("sidebar-shots")
        defer { scene.remove() }
        let shots = AppRefreshSnapshotTests()
        defer { shots.unpin() }

        func shoot<V: View>(_ view: V, _ name: String, dark: Bool, size: CGSize) async throws {
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
            try await Task.sleep(for: .seconds(0.6))
            let rep = try #require(renderedBitmap(host))
            #expect(rep.pixelsWide == Int(size.width) * 2)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try #require(rep.representation(using: .png, properties: [:])).write(to: folder.appending(path: "\(name).png"))
        }

        func sidebar(_ language: String) -> some View {
            LibrarySidebar(model: scene.model)
                .environment(\.locale, Locale(identifier: language))
                .frame(width: 240, height: 420)
                .background(Glass.window)
        }

        for (language, dark) in [("en", false), ("fr", true)] {
            shots.pin(language)
            let tone = dark ? "dark" : "light"
            scene.model.selection = .all
            scene.model.removeStore(.gog)
            scene.model.removeStore(.ea)
            try await shoot(sidebar(language), "sidebar-fresh-\(language)-\(tone)", dark: dark, size: CGSize(width: 240, height: 420))

            scene.model.addStore(.ea)
            scene.model.addStore(.gog)
            scene.model.otherGames.append(Self.game(.installer, "Setup"))
            try await shoot(sidebar(language), "sidebar-added-\(language)-\(tone)", dark: dark, size: CGSize(width: 240, height: 420))
            scene.model.otherGames.removeAll { $0.source == .installer }
        }
    }
}
