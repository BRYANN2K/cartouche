import AppKit
import Testing
@testable import NotProtonApp

// The tab bar, the status capsule and the HUD sit below the notch and the menu bar of the game's screen
@MainActor
@Suite("Overlay safe area")
struct OverlaySafeAreaTests {
    let builtIn = CGRect(x: 0, y: 0, width: 1710, height: 1112)

    @Test("A notched screen: below the notch, 8 pt under it")
    func notch() {
        let area = OverlaySafeArea(safeTop: 38, auxiliary: [CGRect(x: 0, y: 1074, width: 760, height: 38), CGRect(x: 950, y: 1074, width: 760, height: 38)],
                                   screen: builtIn, visible: builtIn)
        #expect(area.top == 38 && area.barTop == 46 && area.screenHeight == 1112)
    }

    @Test("The areas beside the notch count when the insets read nothing")
    func auxiliaryOnly() {
        let area = OverlaySafeArea(safeTop: 0, auxiliary: [CGRect(x: 0, y: 1080, width: 760, height: 32), nil], screen: builtIn, visible: builtIn)
        #expect(area.barTop == 40)
    }

    @Test("A screen whose menu bar shows: below it")
    func menuBar() {
        let screen = CGRect(x: 1710, y: 0, width: 2560, height: 1440)
        let area = OverlaySafeArea(safeTop: 0, auxiliary: [nil, nil], screen: screen, visible: CGRect(x: 1710, y: 0, width: 2560, height: 1415))
        #expect(area.top == 25 && area.barTop == 33)
    }

    @Test("No notch, no menu bar: the mockup's 16 pt")
    func plain() {
        #expect(OverlaySafeArea(safeTop: 0, auxiliary: [nil, nil], screen: builtIn, visible: builtIn).barTop == OS.top)
        #expect(OverlaySafeArea().barTop == OS.top)
    }

    @Test("The in-game HUD gets the safe top and the screen's height through the control block")
    func controlBlock() throws {
        let pid = Int32.random(in: 900_000...990_000)
        let writer = try #require(ControlBlockWriter(pid: pid))
        defer { writer.remove() }
        let center = OverlayCenter(game: OverlayGame(id: "g", name: "G", pid: pid), store: OverlayProfileStore(
            folder: FileManager.default.temporaryDirectory.appending(path: "safe-\(UUID().uuidString)")), soon: [])
        center.safeArea = OverlaySafeArea(safeTop: 38, auxiliary: [nil, nil], screen: builtIn, visible: builtIn)
        writer.write(center.hudControl)
        let block = writer.read()
        #expect(block.safe_top == 38 && block.screen_height == 1112)
    }
}

// The in-game HUD speaks the app's language: a launch variable, then the control block live
@MainActor
@Suite("In-game HUD language")
struct HUDLanguageTests {
    @Test("The launch carries the app's language, and keeps it out under an anti-cheat")
    func launchVariable() {
        defer { OverlayText.use(language: "en") }
        OverlayText.use(language: "fr")
        let metal: Set<AdvancedOption> = [.dlss, .metalHUD]
        #expect(OverlayLaunch.environment(OverlaySettings(), supported: metal, protected: false, existing: [:])["CARTOUCHE_OVERLAY_LANG"] == "fr")
        #expect(OverlayLaunch.environment(OverlaySettings(), supported: metal, protected: true,
                                          existing: ["CARTOUCHE_OVERLAY_LANG": "fr"])["CARTOUCHE_OVERLAY_LANG"] == nil)
        #expect(GameSetupResolver.isAllowed(name: "CARTOUCHE_OVERLAY_LANG", value: "en"))
        OverlayText.use(language: "en")
        #expect(OverlayLaunch.environment(OverlaySettings(), supported: metal, protected: false, existing: [:])["CARTOUCHE_OVERLAY_LANG"] == "en")
    }

    @Test("The control block carries it too")
    func controlBlock() throws {
        defer { OverlayText.use(language: "en") }
        OverlayText.use(language: "fr")
        let writer = try #require(ControlBlockWriter(pid: Int32.random(in: 900_000...990_000)))
        defer { writer.remove() }
        writer.write(HUDControl())
        #expect(ControlBlockWriter.string(writer.read().language) == "fr")
    }
}
