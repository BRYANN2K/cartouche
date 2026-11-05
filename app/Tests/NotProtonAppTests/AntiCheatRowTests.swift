import AppKit
import SwiftUI
import Testing
@testable import NotProtonApp

// The anti-cheat sits in Expected on This Mac; the header above Play is the title and one line,
// so Play has one height for every game. Snapshots only with CARTOUCHE_ANTICHEAT_SNAPSHOTS=<folder>.
@MainActor
@Suite("Anti-cheat row", .serialized)
struct AntiCheatRowTests {
    static let amongUs = SteamFixture.App(id: 945_360, name: "Among Us", installed: true, played: 1_100, minutes: 640)
    static let aimlabs = SteamFixture.App(id: 714_010, name: "Aimlabs", installed: true, played: 12, minutes: 95)
    static let longName = SteamFixture.App(id: 999_001, name: "The Unbearably Long Title of a Game Whose Name Never Fits on One Line",
                                           installed: false, played: nil, minutes: 0)
    static let ids = ["steam:945360", "steam:714010", "steam:999001", "steam:1245620", "steam:367520", "steam:730"]

    struct Scene {
        let fixture: SteamFixture
        let compat: CompatibilityModel
        let model: LibraryModel
        let actions: GameActionRunner
        let activity: ActivityCenter
    }

    final class Tops { var values: [CGFloat] = [] }

    static func scene(_ label: String) async throws -> Scene {
        let fixture = try SteamFixture(label)
        try fixture.writeExport(apps: SteamFixture.apps + [amongUs, aimlabs, longName])
        try fixture.addArt([amongUs.id, aimlabs.id, longName.id, 1_245_620, 367_520, 730])
        let scratch = ScratchDefaults()
        let compat = try await fixtureCompat(fixture.root, defaults: scratch)
        for id in [amongUs.id, aimlabs.id, longName.id, 1_245_620, 367_520, 730] { await compat.openGame(appID: id) }
        let model = libraryModel(fixture, defaults: scratch)
        await model.load()
        let build = try #require(RunnerManifest.current().builds.first { $0.origin == .cartouche })
        model.runners = [Runner(id: build.id, kind: .wineBuild, version: build.version, displayVersion: build.displayVersion,
                                flavors: [.rosetta], state: .ready, build: nil, source: nil, isInstalled: true)]
        model.backendAvailability = BackendAvailability(d3dMetalRunners: [build.id], crossOverWine: [build.id])
        model.antiCheat = { game in game.steamAppID.flatMap { compat.antiCheat(appID: $0)?.name } }
        return Scene(fixture: fixture, compat: compat, model: model, actions: GameActionRunner(model: model, open: { _ in }),
                     activity: ActivitySnapshotTests().center())
    }

    static func panel(_ scene: Scene, _ id: String, language: String, open: Bool = false, tops: Tops? = nil) throws -> some View {
        let game = try #require(scene.model.game(id))
        return GamePanel(game: game, model: scene.model, compat: scene.compat, actions: scene.actions)
            .environment(\.covers, scene.fixture.covers())
            .environment(\.activity, scene.activity)
            .environment(\.advancedOpen, open)
            .environment(\.glassMode, .classic)
            .environment(\.locale, Locale(identifier: language))
            .environment(\.playTop, tops.map { tops in { tops.values.append($0) } })
    }

    @Test("Aimlabs carries EQU8, Among Us no anti-cheat")
    func fixtures() async throws {
        let scene = try await Self.scene("anticheat-row")
        defer { scene.fixture.remove() }
        #expect(scene.compat.panel(appID: Self.amongUs.id, method: .wine).antiCheat == nil)
        #expect(scene.compat.panel(appID: Self.aimlabs.id, method: .wine).antiCheat?.name == "EQU8")
    }

    @Test("The tooltip is one short sentence pair, French and English")
    func reasonCopy() {
        defer { OverlayText.use(language: "en") }
        OverlayText.use(language: "en")
        #expect(AntiCheatRow.reason == "Off and DLSS only, unless Cartouche Engine is on.")
        OverlayText.use(language: "fr")
        #expect(AntiCheatRow.reason == "Non et DLSS seulement, sauf avec le moteur Cartouche.")
        #expect(AntiCheatRow.reason.count <= 75)
    }

    @Test("Play sits at one height whatever the game, its anti-cheat or its title")
    func playAtOneHeight() async throws {
        let scene = try await Self.scene("anticheat-play")
        defer { scene.fixture.remove(); OverlayText.use(language: "en") }
        var seen: [String: CGFloat] = [:]
        for language in ["fr", "en"] {
            OverlayText.use(language: language)
            for id in Self.ids {
                let tops = Tops()
                let host = NSHostingView(rootView: try Self.panel(scene, id, language: language, tops: tops)
                    .frame(width: Glass.panelWidth, height: 980))
                host.frame = CGRect(x: 0, y: 0, width: Glass.panelWidth, height: 980)
                for _ in 0..<40 {
                    host.layoutSubtreeIfNeeded()
                    if !tops.values.isEmpty { break }
                    try await Task.sleep(for: .milliseconds(25))
                }
                seen["\(id)-\(language)"] = try #require(tops.values.last, "no Play for \(id)")
            }
        }
        let first = try #require(seen["steam:945360-fr"])
        #expect(first > 0)
        for (key, top) in seen { #expect(top == first, "\(key): Play at \(top), Among Us at \(first)") }
    }

    @Test("Locked Image shows Off and keeps the stored upscaling")
    func lockedKeepsProfile() async throws {
        let scene = try await Self.scene("anticheat-image")
        defer { scene.fixture.remove() }
        var profile = scene.model.profile(for: "steam:714010")
        profile.upscale = .spatial
        scene.model.setProfile(profile, for: "steam:714010")
        let host = NSHostingView(rootView: try Self.panel(scene, "steam:714010", language: "en", open: true)
            .frame(width: Glass.panelWidth, height: 1700))
        host.frame = CGRect(x: 0, y: 0, width: Glass.panelWidth, height: 1700)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()
        #expect(scene.model.profile(for: "steam:714010").upscale == .spatial)
    }

    // MARK: Snapshots

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CARTOUCHE_ANTICHEAT_SNAPSHOTS"] != nil))
    func snapshots() async throws {
        let folder = URL(filePath: ProcessInfo.processInfo.environment["CARTOUCHE_ANTICHEAT_SNAPSHOTS"] ?? "/tmp")
        let scene = try await Self.scene("anticheat-shots")
        defer { scene.fixture.remove() }
        var off = scene.model.profile(for: "steam:945360")
        off.upscale = .off
        scene.model.setProfile(off, for: "steam:945360")
        let shots = AppRefreshSnapshotTests()
        defer { shots.unpin() }
        let states: [(String, String, Bool, CGFloat)] = [
            ("anticheat-row-amongus", "steam:945360", false, 980),
            ("anticheat-row-aimlabs", "steam:714010", false, 980),
            ("image-upscaling-off", "steam:945360", true, 1700),
            ("image-locked", "steam:714010", true, 1700),
        ]
        for language in AppRefreshSnapshotTests.languages {
            shots.pin(language)
            var tops: [CGFloat] = []
            for dark in [false, true] {
                for (name, id, open, height) in states {
                    let seen = Tops()
                    let panel = try Self.panel(scene, id, language: language, open: open, tops: seen)
                        .frame(width: Glass.panelWidth, height: height)
                        .background(Glass.window)
                    try await shots.capture(panel, dark: dark, to: folder.appending(path: "\(name)-\(language)-\(dark ? "dark" : "light").png"))
                    tops.append(try #require(seen.values.last))
                }
            }
            #expect(Set(tops).count == 1, "Play heights in \(language): \(tops)")
        }
    }
}
