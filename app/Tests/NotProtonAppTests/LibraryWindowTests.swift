import Foundation
import RetroArchKit
import SwiftUI
import Testing

@testable import NotProtonApp

// Each screen state rendered as a whole window, in light and dark, and with the
// macOS 15 look forced on this Mac. PNGs go to CARTOUCHE_SNAPSHOTS when it is set.
@Suite("Library window and screen states")
@MainActor
struct LibraryWindowTests {

    @MainActor
    struct Scene {
        let fixture: SteamFixture
        let scratch = ScratchDefaults()
        let model: LibraryModel
        let compat: CompatibilityModel
        let setup: SteamSetup

        init(_ label: String, steam installed: Bool = true, export: Bool = true, art: Bool = true) async throws {
            fixture = try SteamFixture(label)
            if export { try fixture.writeExport() }
            if art { try fixture.addArt(SteamFixture.apps.map(\.id)) }
            model = libraryModel(fixture, installed: installed, defaults: scratch)
            compat = try await fixtureCompat(fixture.root, defaults: scratch)
            var steps = SteamSetup.Steps()
            steps.brewPath = { "/opt/homebrew/bin/brew" }
            setup = SteamSetup(steps: steps, defaults: scratch.defaults)
        }

        func window(_ mode: GlassMode = .liquid) -> some View {
            LibraryWindow(model: model, compat: compat, steamSetup: setup,
                          actions: GameActionRunner(model: model, open: { _ in }))
                .environment(\.covers, fixture.covers())
                .environment(\.glassMode, mode)
        }

        func render(_ name: String, modes: [GlassMode] = [.liquid, .classic]) async {
            for mode in modes {
                for dark in [false, true] {
                    let size = await windowSnapshot(window(mode), named: mode == .classic ? "\(name)-macos15" : name, dark: dark)
                    #expect(size.width >= 1280)
                }
            }
        }
    }

    @Test("All Games with covers, gray when not installed, the panel on Elden Ring")
    func allGames() async throws {
        let scene = try await Scene("all")
        defer { scene.fixture.remove() }
        await scene.model.load()
        scene.model.toggleFavorite("steam:1245620")
        scene.model.select("steam:1245620")
        await scene.compat.openGame(appID: 1_245_620)
        #expect(scene.model.screen.sections.map(\.title) == ["Steam"])
        await scene.render("library-all-games")
    }

    @Test("The Steam source: no section header, the toolbar names the account")
    func steamSource() async throws {
        let scene = try await Scene("steam")
        defer { scene.fixture.remove() }
        await scene.model.load()
        scene.model.selection = .source(.steam)
        scene.model.select("steam:1172470")
        #expect(scene.model.subtitle == "8 games. Signed in as player42")
        await scene.render("library-steam-selected-gray", modes: [.liquid])
    }

    // The window's sidebar is vibrant, which an offscreen capture cannot draw, so the
    // same sidebar view is also rendered on its own
    @Test("Sidebar structure renders: Library, PC and an empty Consoles section with its + button")
    func sidebarAlone() async throws {
        let scene = try await Scene("sidebar")
        defer { scene.fixture.remove() }
        await scene.model.load()
        scene.model.toggleFavorite("steam:1245620")
        for dark in [false, true] {
            let size = snapshot(LibrarySidebar(model: scene.model).frame(width: 240, height: 420),
                                named: "sidebar", dark: dark)
            #expect(size.width >= 240)
        }
    }

    @Test("States are reachable: loading")
    func loading() async throws {
        let scene = try await Scene("loading")
        defer { scene.fixture.remove() }
        #expect(scene.model.screen == .loading)
        await scene.render("state-loading")
    }

    @Test("States are reachable: empty library")
    func empty() async throws {
        let scene = try await Scene("empty", steam: false, export: false, art: false)
        defer { scene.fixture.remove() }
        await scene.model.load()
        #expect(scene.model.screen == .welcome)
        await scene.render("state-empty")
    }

    @Test("States are reachable: offline")
    func offline() async throws {
        let scene = try await Scene("offline")
        defer { scene.fixture.remove() }
        await scene.model.load()
        scene.model.isOffline = true
        scene.model.select("steam:1172470")
        // Install needs the network
        let apex = try #require(scene.model.game("steam:1172470"))
        #expect(GameMenu.items(for: apex, in: scene.model).first?.disabled == true)
        await scene.render("state-offline")
    }

    @Test("States are reachable: expired session")
    func expired() async throws {
        let scene = try await Scene("expired")
        defer { scene.fixture.remove() }
        await scene.model.load()
        scene.model.stores[.epic] = .expired(account: "player42")
        scene.model.otherGames = [Game(id: "epic:control", source: .epic, name: "Control", installed: false)]
        scene.model.selection = .source(.epic)
        #expect(scene.model.expiredStore == .epic)
        await scene.render("state-expired-session")
    }

    @Test("States are reachable: Steam not installed")
    func steamMissing() async throws {
        let scene = try await Scene("missing", steam: false, export: false, art: false)
        defer { scene.fixture.remove() }
        await scene.model.load()
        scene.model.selection = .source(.steam)
        #expect(scene.model.screen == .steamInstall)
        await scene.render("state-steam-not-installed")
    }

    @Test("States are reachable: no search result")
    func noResult() async throws {
        let scene = try await Scene("search")
        defer { scene.fixture.remove() }
        await scene.model.load()
        scene.model.searchText = "zelda"
        #expect(scene.model.screen == .noResults("zelda"))
        await scene.render("state-no-search-result")
    }

    @Test("States are reachable: a store to sign in to, empty favorites")
    func otherStates() async throws {
        let scene = try await Scene("others")
        defer { scene.fixture.remove() }
        await scene.model.load()
        scene.model.selection = .source(.gog)
        await scene.render("state-sign-in", modes: [.liquid])
        scene.model.selection = .favorites
        #expect(scene.model.screen == .emptyFavorites)
        await scene.render("state-empty-favorites", modes: [.liquid])
    }

    @Test("Reduce Motion: no tilt, no grid spring, fades instead of springs")
    func reduceMotion() {
        let reduced = Motion(reduceMotion: true)
        #expect(!reduced.tilts)
        #expect(reduced.grid == nil)
        #expect(reduced.panel == .easeInOut(duration: 0.15))
        let full = Motion(reduceMotion: false)
        #expect(full.tilts)
        #expect(full.grid != nil)
    }

    @Test("macOS 15 gets standard materials: glass only where the system has it")
    func glassMode() {
        if #available(macOS 26, *) {
            #expect(GlassMode.system == .liquid)
        } else {
            #expect(GlassMode.system == .classic)
        }
    }
}

@Suite("Settings window")
@MainActor
struct SettingsWindowTests {

    @Test("Tabs: General, Library, Accounts, Compatibility, Privacy, Consoles, Controllers and Agents")
    func tabs() {
        #expect(SettingsTab.allCases.map(\.title) == ["General", "Library", "Accounts", "Compatibility", "Privacy", "Consoles", "Controllers", "Agents"])
    }

    @Test("Each tab renders in light and dark")
    func renders() async throws {
        let fixture = try SteamFixture("settings")
        defer { fixture.remove() }
        try fixture.writeExport()
        let scratch = ScratchDefaults()
        let model = libraryModel(fixture, defaults: scratch)
        await model.load()
        model.hide("steam:730")
        let tcc = FakeTCC([.appManagement: .granted, .notifications: .undetermined])
        let center = makeCenter(tcc, scratch)
        await center.refresh()
        let paths = RetroArchPaths(root: fixture.root.appending(path: "retroarch"))
        let consoles = ConsolesSettingsModel(paths: paths, includedApp: fixture.root.appending(path: "RetroArch.app"),
                                             cores: CoreManager(paths: paths), official: OfficialRelease(paths: paths),
                                             probe: { _ in nil })
        let agentBackend = AgentFixture(home: fixture.root)
        let agentService = AgentService(backend: agentBackend, level: .standard, home: fixture.root)
        agentService.notify = { _ in }
        let agents = AgentControlModel(service: agentService, defaults: scratch.defaults)
        let panes: [(SettingsTab, AnyView)] = [
            (.general, AnyView(GeneralSettingsView())),
            (.library, AnyView(LibrarySettingsView(model: model))),
            (.accounts, AnyView(AccountsSettingsView(model: model))),
            (.compatibility, AnyView(CompatibilitySettingsView(model: model))),
            (.privacy, AnyView(PrivacySettingsView(center: center, choices: PrivacyChoices(defaults: scratch.defaults)))),
            (.consoles, AnyView(ConsolesSettingsView(model: consoles, chooseApp: { nil }))),
            (.agents, AnyView(AgentsSettingsView(model: agents))),
        ]
        for (tab, view) in panes {
            for dark in [false, true] {
                let size = await windowSnapshot(view, named: "settings-\(tab.rawValue)", size: CGSize(width: 640, height: 560), dark: dark)
                #expect(size.width >= 640)
            }
        }
        #expect(tcc.requests.isEmpty)
    }
}
