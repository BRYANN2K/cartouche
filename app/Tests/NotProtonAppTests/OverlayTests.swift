import AppKit
import Carbon.HIToolbox
import CartoucheIdentity
import Foundation
import Testing
@testable import NotProtonApp

@MainActor
final class FakeRegistrar: HotkeyRegistrar {
    var refused: Set<HotkeyCombo> = []
    var active: [UInt32: HotkeyCombo] = [:]

    func register(_ combo: HotkeyCombo, id: UInt32) -> Bool {
        guard !refused.contains(combo) else { return false }
        active[id] = combo
        return true
    }

    func unregisterAll() { active.removeAll() }
}

private final class FakeCounter: ExternalFrameCounting, @unchecked Sendable {
    var starts = 0
    var startResult = true
    var dead = false
    var value: GameMetrics?

    func start(pid: pid_t) async -> Bool { starts += 1; return startResult }
    func stop() async {}
    func metrics(now: Double) -> GameMetrics? { value }
}

private func scratchDefaults() -> UserDefaults {
    let name = "overlay-tests-\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return d
}

private func scratchStore() -> OverlayProfileStore {
    OverlayProfileStore(folder: FileManager.default.temporaryDirectory.appending(path: "overlay-\(UUID().uuidString)"))
}

private let game = OverlayGame(id: "hollow-pines", name: "Hollow Pines", pid: 4242, dlss: true)
private let protectedGame = OverlayGame(id: "arena", name: "Arena", pid: 4243, dlss: true, antiCheat: "Easy Anti-Cheat")
private let protectedNoDLSS = OverlayGame(id: "deadlock", name: "Deadlock", pid: 4244, dlss: false, antiCheat: "VAC")

private func metrics(_ fps: Double = 59) -> GameMetrics {
    GameMetrics(presentedFPS: fps, realFPS: 58, low1FPS: 51, frameMs: 16.9, latencyMs: 25, gpuPercent: 70, thermal: 0,
                frameTimes: Array(repeating: 16.9, count: 120))
}

@MainActor
@Suite("In-game overlay", .serialized)
struct OverlayTests {
    init() { OverlayText.use(language: "fr") }

    // MARK: Shortcut

    @Test("Default shortcut is ⌥C with ⌥⇧C for the HUD")
    func defaultShortcut() {
        let keys = FakeRegistrar()
        let menu = OverlayHotkey.register(stored: nil, with: keys)
        #expect(menu == .optionC)
        #expect(menu?.label == "⌥C")
        #expect(keys.active[OverlayHotkey.menuID] == .optionC)
        #expect(keys.active[OverlayHotkey.hudID]?.label == "⌥⇧C")
        let defaults = scratchDefaults()
        #expect(OverlayHotkey.hud(defaults) == .optionShiftC)
    }

    @Test("No fallback when ⌥C is taken: the HUD shortcut still registers")
    func takenShortcut() {
        let keys = FakeRegistrar()
        keys.refused = [.optionC]
        #expect(OverlayHotkey.register(stored: nil, with: keys) == nil)
        #expect(keys.active[OverlayHotkey.menuID] == nil)
        #expect(keys.active[OverlayHotkey.hudID] == .optionShiftC)
    }

    @Test("A stored shortcut is registered alone, without fallback")
    func userShortcut() {
        let keys = FakeRegistrar()
        let mine = HotkeyCombo(keyCode: 0x22, modifiers: UInt32(1 << 11 | 1 << 12))
        #expect(OverlayHotkey.register(stored: mine, with: keys)?.label == "⌃⌥I")
        keys.refused = [mine]
        #expect(OverlayHotkey.register(stored: mine, with: keys) == nil)
        #expect(keys.active[OverlayHotkey.menuID] == nil)
        let defaults = scratchDefaults()
        OverlayHotkey.store(mine, defaults)
        #expect(OverlayHotkey.stored(defaults) == mine)
    }

    @Test("System combinations are refused: ⌘ without ⌥ or ⌃, ⌃⌘Q, ⌥⌘Esc and the reserved ⌥⌘R")
    func systemCombosRefused() {
        let cmdQ = HotkeyCombo(keyCode: 12, modifiers: UInt32(cmdKey))
        #expect(cmdQ.reserved)
        #expect(OverlayHotkey.refusal(of: cmdQ, other: .optionC) != nil)
        #expect(HotkeyCombo(keyCode: 12, modifiers: UInt32(cmdKey | shiftKey)).reserved)
        // ⌃⌘Q locks the screen, ⌥⌘Esc force-quits: macOS keeps both
        #expect(HotkeyCombo(keyCode: 12, modifiers: UInt32(cmdKey | controlKey)).reserved)
        #expect(HotkeyCombo(keyCode: UInt32(kVK_Escape), modifiers: UInt32(optionKey | cmdKey)).reserved)
        #expect(OverlayHotkey.refusal(of: HotkeyCombo(keyCode: 12, modifiers: UInt32(cmdKey | controlKey)), other: .optionC) != nil)
        #expect(HotkeyCombo.resources.reserved)
        #expect(OverlayHotkey.refusal(of: .resources, other: .optionC) != nil)
        // ⌘ stays usable with ⌥ or ⌃
        #expect(!HotkeyCombo(keyCode: 14, modifiers: UInt32(optionKey | cmdKey)).reserved)
        #expect(OverlayHotkey.refusal(of: HotkeyCombo(keyCode: 14, modifiers: UInt32(optionKey | cmdKey)), other: .optionC) == nil)
    }

    @Test("The menu and the HUD cannot share a combination")
    func menuHudDuplicateRefused() {
        #expect(OverlayHotkey.refusal(of: .optionC, other: .optionC) != nil)
        #expect(OverlayHotkey.refusal(of: .optionC, other: .optionShiftC) == nil)
        // A stored collision moves the HUD back to its own default
        let defaults = scratchDefaults()
        OverlayHotkey.store(.optionShiftC, defaults)
        OverlayHotkey.store(.optionShiftC, defaults, key: OverlayHotkey.hudKey)
        #expect(OverlayHotkey.hud(defaults) == .optionC)
        let keys = FakeRegistrar()
        #expect(OverlayHotkey.register(stored: OverlayHotkey.stored(defaults), hud: OverlayHotkey.hud(defaults), with: keys) == .optionShiftC)
        #expect(keys.active[OverlayHotkey.hudID] == .optionC)
    }

    @Test("« Par défaut » answers like a recorded press: refused when it would double the other line")
    func defaultButtonDuplicateRefused() {
        // Menu on a custom ⌥⇧C, HUD on its own ⌥C: the menu's Default must be refused, not silent
        #expect(OverlayHotkey.refusal(ofDefault: .optionC, other: .optionC) != nil)
        #expect(OverlayHotkey.refusal(ofDefault: .optionShiftC, other: .optionC) == nil)
        #expect(OverlayHotkey.refusal(ofDefault: .optionC, other: .optionShiftC) == nil)
    }

    @Test("An invalid stored shortcut falls back to the defaults")
    func invalidStoredShortcut() {
        let defaults = scratchDefaults()
        OverlayHotkey.store(HotkeyCombo(keyCode: 12, modifiers: UInt32(cmdKey)), defaults)
        #expect(OverlayHotkey.stored(defaults) == nil)
        OverlayHotkey.store(.resources, defaults, key: OverlayHotkey.hudKey)
        #expect(OverlayHotkey.stored(defaults, key: OverlayHotkey.hudKey) == nil)
        #expect(OverlayHotkey.hud(defaults) == .optionShiftC)
        let keys = FakeRegistrar()
        #expect(OverlayHotkey.register(stored: OverlayHotkey.stored(defaults), hud: OverlayHotkey.hud(defaults), with: keys) == .optionC)
        #expect(keys.active[OverlayHotkey.menuID] == .optionC)
    }

    @Test("While recording: Escape cancels, a refused combo keeps recording, a good one is taken")
    func recordedKeys() throws {
        let esc = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                windowNumber: 0, context: nil, characters: "\u{1b}",
                                                charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        #expect(OverlayController.recordResult(for: esc, other: .optionShiftC) == .cancel)
        let plain = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                  windowNumber: 0, context: nil, characters: "c",
                                                  charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8))
        #expect(OverlayController.recordResult(for: plain, other: .optionShiftC) == .swallow)
        let cmdQ = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
                                                 windowNumber: 0, context: nil, characters: "q",
                                                 charactersIgnoringModifiers: "q", isARepeat: false, keyCode: 12))
        guard case .refuse = OverlayController.recordResult(for: cmdQ, other: .optionShiftC) else { Issue.record("⌘Q must be refused"); return }
        let optE = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.option, .command], timestamp: 0,
                                                 windowNumber: 0, context: nil, characters: "e",
                                                 charactersIgnoringModifiers: "e", isARepeat: false, keyCode: 14))
        #expect(OverlayController.recordResult(for: optE, other: .optionShiftC) == .take(HotkeyCombo(keyCode: 14, modifiers: UInt32(optionKey | cmdKey))))
        // Closing the menu stops the recording too
        let center = OverlayCenter(game: game, store: scratchStore())
        center.setOpen(true)
        center.recordingShortcut = true
        center.setOpen(false)
        #expect(!center.recordingShortcut)
    }

    @Test("The shortcut exists only while a game runs")
    func shortcutLifetime() {
        let keys = FakeRegistrar()
        let controller = OverlayController(hotkeys: keys, defaults: scratchDefaults())
        #expect(keys.active.isEmpty)
        controller.gameStarted()
        #expect(keys.active[OverlayHotkey.menuID] == .optionC)
        controller.gameEnded()
        #expect(keys.active.isEmpty)
        #expect(controller.registered == nil)
    }

    // MARK: Panel, focus, outside click

    @Test("Panel sits at .screenSaver over the whole screen")
    func panelConfiguration() throws {
        let screen = try #require(NSScreen.screens.first)
        let panel = OverlayPanel(screen: screen)
        #expect(panel.level == .screenSaver)
        #expect(panel.frame == screen.frame)
        #expect(panel.canBecomeKey)
        #expect(!panel.hidesOnDeactivate)
        for b in [NSWindow.CollectionBehavior.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle] {
            #expect(panel.collectionBehavior.contains(b))
        }
        #expect(!panel.styleMask.contains(.nonactivatingPanel))
    }

    @Test("The game page's button opens the menu for its own game, not Wine's explorer")
    func pageButtonPicksItsGame() {
        let explorer = OverlayGame(id: "explorer", name: "explorer", pid: 10, dlss: false)
        let pines = OverlayGame(id: "steam:7", name: "Hollow Pines", pid: 11, dlss: true)
        #expect(OverlayController.pick([explorer, pines], id: "steam:7") == pines)
        #expect(OverlayController.pick([explorer, pines], id: nil) == explorer)
        #expect(OverlayController.pick([explorer], id: "steam:7") == explorer)
        #expect(OverlayController.pick([], id: "steam:7") == nil)
    }

    @Test("Opening activates Cartouche, closing activates the game, the shortcut toggles")
    func focusGoesBack() throws {
        let keys = FakeRegistrar()
        let controller = OverlayController(hotkeys: keys, defaults: scratchDefaults())
        var selfActivations = 0
        var games: [pid_t] = []
        controller.activation = OverlayActivation(activateSelf: { selfActivations += 1 }, activateGame: { games.append($0) },
                                                  show: { _ in }, hide: { _ in }, showHUD: { _ in })
        controller.activation.settle = { $0() }
        controller.activation.tellGame = { _, _ in }
        controller.resolveGame = { _ in game }
        let screen = try #require(NSScreen.screens.first)
        controller.open(game: game, screen: screen)
        #expect(controller.isOpen)
        controller.hotkeyFired(OverlayHotkey.menuID)
        #expect(!controller.isOpen)
        #expect(selfActivations == 1)
        #expect(games == [game.pid])
        controller.gameEnded()
    }

    @Test("Fullscreen game: the panel shows before Cartouche activates, and the app's windows wait for the user to come back")
    func panelAlone() async throws {
        let controller = OverlayController(hotkeys: FakeRegistrar(), defaults: scratchDefaults())
        let library = NSWindow(contentRect: .init(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        var events: [String] = []
        var restored: [NSWindow] = []
        var options: NSApplication.PresentationOptions = []
        var restoredGames: [pid_t] = []
        controller.activation = OverlayActivation(
            activateSelf: { events.append("activate") }, activateGame: { _ in events.append("game") },
            restoreGame: { restoredGames.append($0) },
            show: { _ in events.append("show") }, hide: { _ in events.append("hide panel") }, showHUD: { _ in },
            hideWindows: { events.append("hide windows"); return [library] },
            restoreWindows: { _ in events.append("restore") },
            bringBack: { restored = $0; events.append("bring back") },
            presentation: { new in let old = options; options = new; events.append("options"); return old })
        controller.activation.settle = { $0() }
        controller.activation.tellGame = { _, _ in }
        var frontWaits: [pid_t] = []
        controller.activation.whenGameFront = { pid, _, work in
            frontWaits.append(pid)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { MainActor.assumeIsolated { work() } }
        }
        let screen = try #require(NSScreen.screens.first)
        controller.open(game: game, screen: screen)
        #expect(events == ["hide windows", "options", "show", "activate"])
        #expect(options == [.hideDock, .hideMenuBar])
        controller.close()
        #expect(options == [.hideDock, .hideMenuBar], "kept until the game has the focus")
        #expect(frontWaits == [game.pid], "Cartouche hides only once the game is in front")
        try await Task.sleep(for: .milliseconds(400))
        #expect(options == [])
        #expect(events.suffix(3) == ["game", "hide panel", "options"])
        #expect(!events.contains("restore"), "ordering a window in from the game's Space would switch Spaces")
        #expect(controller.pendingWindows == [library])
        #expect(restoredGames == [game.pid], "a fullscreen game minimized by the focus change comes back")
        controller.open(game: game, screen: screen)
        controller.appBecameActive()
        #expect(restored.isEmpty, "the menu opening is not the user coming back")
        controller.close()
        try await Task.sleep(for: .milliseconds(400))
        controller.appBecameActive()
        #expect(restored == [library])
        #expect(controller.pendingWindows.isEmpty)
        controller.gameEnded()
    }

    @Test("The game's Wine hears of the menu before Cartouche takes the focus, and after the game has it back")
    func gameNotices() async throws {
        let controller = OverlayController(hotkeys: FakeRegistrar(), defaults: scratchDefaults())
        var events: [String] = []
        var later: [@MainActor () -> Void] = []
        controller.activation = OverlayActivation(
            activateSelf: { events.append("activate") }, activateGame: { _ in events.append("game") },
            show: { _ in events.append("show") }, hide: { _ in }, showHUD: { _ in },
            hideWindows: { [] }, restoreWindows: { _ in }, presentation: { _ in [] })
        controller.activation.tellGame = { pid, notice in events.append("\(notice)") ; #expect(pid == game.pid) }
        controller.activation.settle = { later.append($0) }
        controller.activation.restoreGame = { _ in }
        let screen = try #require(NSScreen.screens.first)
        controller.open(game: game, screen: screen)
        #expect(events == ["willOpen", "show"], "no focus change before the game's Wine has the notice")
        later.forEach { $0() }
        #expect(events == ["willOpen", "show", "activate"])
        controller.close()
        #expect(events.suffix(2) == ["game", "didClose"])
        controller.gameEnded()
    }

    // 488a93f9: the game's own HUD and Cartouche's stand-in showed the FPS twice
    @Test("A game whose metrics block exists already draws the HUD: the menu never adds a second one")
    func noDoubleHUD() throws {
        let controller = OverlayController(hotkeys: FakeRegistrar(), defaults: scratchDefaults())
        controller.activation = OverlayActivation(
            activateSelf: {}, activateGame: { _ in }, show: { _ in }, hide: { _ in }, showHUD: { _ in },
            hideWindows: { [] }, restoreWindows: { _ in }, presentation: { _ in [] })
        controller.activation.settle = { _ in }
        controller.activation.tellGame = { _, _ in }
        controller.activation.restoreGame = { _ in }
        var asked: [pid_t] = []
        controller.libraryPublishes = { asked.append($0); return true }
        // Launched by another Cartouche, and protected: nothing says the library is in, but its block is there
        var protected = game
        protected.antiCheat = "Easy Anti-Cheat"
        controller.open(game: protected, screen: try #require(NSScreen.screens.first))
        let center = try #require(controller.center)
        #expect(asked == [game.pid])
        #expect(center.game.libraryLoaded)
        #expect(!center.hudOutside, "the library's HUD is already in the game")
        controller.close()
        controller.gameEnded()

        // Without the block, Cartouche's own HUD stands in
        let other = OverlayController(hotkeys: FakeRegistrar(), defaults: scratchDefaults())
        other.activation = controller.activation
        other.libraryPublishes = { _ in false }
        other.open(game: protected, screen: try #require(NSScreen.screens.first))
        #expect(other.center?.hudOutside == true)
        other.close()
        other.gameEnded()
    }

    @Test("Windowed game: the app's windows come back behind the game as soon as the menu closes")
    func windowedRestore() async throws {
        let controller = OverlayController(hotkeys: FakeRegistrar(), defaults: scratchDefaults())
        let library = NSWindow(contentRect: .init(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        var restored: [NSWindow] = []
        controller.activation = OverlayActivation(
            activateSelf: {}, activateGame: { _ in }, show: { _ in }, hide: { _ in }, showHUD: { _ in },
            hideWindows: { [library] }, restoreWindows: { restored = $0 }, presentation: { _ in [] })
        controller.activation.settle = { $0() }
        controller.activation.tellGame = { _, _ in }
        let screen = try #require(NSScreen.screens.first)
        let window = CGRect(x: screen.frame.minX + 100, y: screen.frame.minY + 100, width: 800, height: 450)
        controller.locate = { _ in OverlayPlacement(rect: window, safeArea: OverlaySafeArea(screen)) }
        controller.open(game: game)
        controller.close()
        try await Task.sleep(for: .milliseconds(400))
        #expect(restored == [library])
        #expect(controller.pendingWindows.isEmpty)
        controller.gameEnded()
    }

    @Test("Cartouche hidden at launch: its windows leave before activation unhides it, and it hides again after")
    func hiddenApp() async throws {
        let controller = OverlayController(hotkeys: FakeRegistrar(), defaults: scratchDefaults())
        let library = NSWindow(contentRect: .init(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        var events: [String] = []
        controller.activation = OverlayActivation(
            activateSelf: { events.append("activate") }, activateGame: { _ in events.append("game") },
            show: { _ in }, hide: { _ in }, showHUD: { _ in },
            hideWindows: { events.append("hide windows"); return [library] },
            restoreWindows: { _ in events.append("restore") }, presentation: { _ in [] },
            appHidden: { true }, hideApp: { events.append("hide app") })
        controller.activation.settle = { $0() }
        controller.activation.tellGame = { _, _ in }
        let screen = try #require(NSScreen.screens.first)
        controller.open(game: game, screen: screen)
        #expect(events == ["hide windows", "activate"])
        controller.close()
        try await Task.sleep(for: .milliseconds(400))
        #expect(events.suffix(2) == ["game", "hide app"])
        #expect(!events.contains("restore"), "a hidden Cartouche keeps its windows until the user comes back")
        #expect(controller.pendingWindows == [library])
        events = []
        controller.activation.appHidden = { false }
        controller.open(game: game, screen: screen)
        controller.close()
        try await Task.sleep(for: .milliseconds(400))
        #expect(!events.contains("hide app"), "a visible Cartouche stays visible")
        controller.gameEnded()
    }

    @Test("While hidden, the windows to leave are the ones shown before the hide, never the closed ones")
    func hiddenWindowsChosen() throws {
        let library = NSWindow(contentRect: .init(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        let settings = NSWindow(contentRect: .init(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        let panel = OverlayPanel(screen: try #require(NSScreen.screens.first))
        #expect(OverlayWindows.shown(hidden: false, windows: [library, settings], beforeHide: [library]).isEmpty)
        #expect(OverlayWindows.shown(hidden: true, windows: [library, settings], beforeHide: [library, panel]) == [library])
    }

    @Test("The menu and the HUD panels stay when Cartouche hides")
    func panelsSurviveHide() throws {
        let screen = try #require(NSScreen.screens.first)
        #expect(!OverlayPanel(screen: screen).canHide)
        #expect(!OverlayPanel(screen: screen, activating: false).canHide)
    }

    @Test("A windowed game: the menu covers its window, with the window's safe area")
    func windowedPanel() throws {
        let controller = OverlayController(hotkeys: FakeRegistrar(), defaults: scratchDefaults())
        var frames: [CGRect] = []
        controller.activation = OverlayActivation(activateSelf: {}, activateGame: { _ in }, show: { frames.append($0.frame) },
                                                  hide: { _ in }, showHUD: { _ in }, hideWindows: { [] }, restoreWindows: { _ in },
                                                  presentation: { _ in [] })
        controller.activation.settle = { $0() }
        controller.activation.tellGame = { _, _ in }
        let rect = CGRect(x: 880, y: 495, width: 800, height: 450)
        var area = OverlaySafeArea()
        area.screenHeight = 450
        controller.locate = { _ in OverlayPlacement(rect: rect, safeArea: area) }
        controller.open(game: game)
        #expect(frames == [rect])
        #expect(controller.center?.safeArea.screenHeight == 450)
        controller.close()
        controller.gameEnded()
    }

    @Test("The outside HUD sits over the game's window and follows it")
    func hudFollowsWindow() async throws {
        let controller = OverlayController(hotkeys: FakeRegistrar(), defaults: scratchDefaults())
        var huds: [NSPanel] = []
        controller.activation = OverlayActivation(activateSelf: {}, activateGame: { _ in }, show: { _ in }, hide: { _ in },
                                                  showHUD: { huds.append($0) }, hideWindows: { [] }, restoreWindows: { _ in },
                                                  presentation: { _ in [] })
        controller.activation.settle = { $0() }
        controller.activation.tellGame = { _, _ in }
        var rect = CGRect(x: 100, y: 100, width: 800, height: 450)
        controller.locate = { _ in OverlayPlacement(rect: rect, safeArea: OverlaySafeArea()) }
        controller.open(game: protectedGame)
        controller.close()
        let hud = try #require(huds.first)
        #expect(hud.frame == rect)
        rect = CGRect(x: 300, y: 200, width: 1024, height: 576)
        try await Task.sleep(for: .milliseconds(1200))
        #expect(hud.frame == rect)
        controller.gameEnded()
    }

    @Test("Hidden while the menu is open: the app's own windows, never the status item, the menu's panels or sheets")
    func windowsHidden() {
        #expect(OverlayWindows.hides(level: .normal, visible: true, overlay: false, attached: false))
        #expect(OverlayWindows.hides(level: .floating, visible: true, overlay: false, attached: false))
        #expect(!OverlayWindows.hides(level: .statusBar, visible: true, overlay: false, attached: false))
        #expect(!OverlayWindows.hides(level: .screenSaver, visible: true, overlay: true, attached: false))
        #expect(!OverlayWindows.hides(level: .normal, visible: false, overlay: false, attached: false))
        #expect(!OverlayWindows.hides(level: .normal, visible: true, overlay: false, attached: true))
    }

    @Test("An outside click cancels a confirmation first, then closes")
    func outsideClick() {
        var nav = OverlayNavigation()
        let first = nav.clickOutside()
        #expect(first)
        nav.quitArmed = true
        let armed = nav.clickOutside()
        #expect(!armed)
        #expect(!nav.quitArmed)
        let again = nav.clickOutside()
        #expect(again)
    }

    // MARK: Tabs, motion

    @Test("Eight tabs in the mockup's order and labels")
    func tabs() {
        #expect(OverlaySection.allCases.map(\.title) == ["Performance", "Upscaling", "Génération d’images", "Apps en arrière-plan",
                                                         "Affichage", "Capture", "Manette", "Notes"])
        #expect(OverlaySection.allCases.map(\.short) == ["Perf.", "Upscaling", "Génération", "Apps", "Affichage", "Capture", "Manette", "Notes"])
    }

    @Test("Pointer slides the content 8 pt, keyboard and Reduce Motion do not")
    func motion() {
        var nav = OverlayNavigation()
        nav.go(.upscaling, by: .pointer)
        #expect(OverlayMotion.contentOffset(slide: nav.slide, input: nav.input, reduce: false) == 8)
        nav.go(.performance, by: .pointer)
        #expect(OverlayMotion.contentOffset(slide: nav.slide, input: nav.input, reduce: false) == -8)
        nav.go(.upscaling, by: .keyboard)
        #expect(OverlayMotion.contentOffset(slide: nav.slide, input: nav.input, reduce: false) == 0)
        #expect(OverlayMotion.contentOffset(slide: 1, input: .pointer, reduce: true) == 0)
        #expect(OverlayMotion.pill(true) == nil)
        #expect(OverlayMotion.open(true) == .easeInOut(duration: 0.12))
    }

    // MARK: Real data

    @Test("The metrics block is read and shown in French")
    func metricsBlock() throws {
        let pid = getpid()
        let name = String(format: FG_METRICS_NAME, pid)
        let fd = cartouche_shm_open_write(name)
        #expect(fd >= 0)
        defer { shm_unlink(name) }
        #expect(ftruncate(fd, off_t(FG_METRICS_SIZE)) == 0)
        let map = try #require(mmap(nil, Int(FG_METRICS_SIZE), PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0))
        close(fd)
        defer { munmap(map, Int(FG_METRICS_SIZE)) }
        let b = map.assumingMemoryBound(to: FGMetricsBlock.self)
        b.pointee.magic = FG_METRICS_MAGIC
        b.pointee.version = FG_METRICS_VERSION
        b.pointee.size = FG_METRICS_SIZE
        b.pointee.pid = pid
        b.pointee.sequence = 2
        b.pointee.presented_fps = 59
        b.pointee.real_fps = 58
        b.pointee.low1_fps = 51
        b.pointee.frame_ms = 16.9
        b.pointee.added_latency_ms = 25
        b.pointee.frame_count = 3
        #expect(MetricsBlockReader.read(pid: pid).flatMap(MetricsBlockReader.metrics) == nil)
        b.pointee.seconds = 4
        let m = try #require(MetricsBlockReader.read(pid: pid).flatMap(MetricsBlockReader.metrics))
        #expect(OverlayFormat.whole(m.presentedFPS) == "59")
        #expect(m.realFPS.map(OverlayFormat.whole) == "58")
        #expect(OverlayFormat.whole(m.low1FPS) == "51")
        #expect(OverlayFormat.decimal(m.frameMs) == "16,9")
        #expect(m.latencyMs.map(OverlayFormat.whole) == "25")
        #expect(m.frameTimes.count == 3)
        b.pointee.sequence = 3
        #expect(MetricsBlockReader.read(pid: pid) == nil)
    }

    @Test("Without metrics: dashes and « En attente du jeu »")
    func metricsMissing() {
        #expect(MetricsBlockReader.read(pid: 999_999) == nil)
        let c = OverlayContext(game: game)
        #expect(OverlayLayout.verdict(c).title == "En attente du jeu")
        #expect(!c.framesKnown)
    }

    @Test("Notes persist per game")
    func notes() {
        let store = scratchStore()
        let center = OverlayCenter(game: game, store: store, soon: [])
        center.notes = "Code du coffre : 4-1-7"
        let again = OverlayCenter(game: game, store: store, soon: [])
        #expect(again.notes == "Code du coffre : 4-1-7")
        #expect(OverlayCenter(game: protectedGame, store: store, soon: []).notes.isEmpty)
    }

    @Test("No heavy app: « Aucune app lourde »")
    func noHeavyApps() {
        var c = OverlayContext(game: game)
        c.live.apps = [OverlayApp(pid: 10, name: "Notes", cpu: 0.5, gpu: 0, memoryGB: 0.1)]
        #expect(OverlayLayout.blocks(.resources, c).contains(.empty(symbol: "checkmark", title: "Aucune app lourde", action: nil)))
        c.live.apps[0].paused = true
        #expect(OverlayLayout.rows(.resources, c).first?.id == .app(10))
    }

    // MARK: HUD control

    @Test("HUD level is written live with an even sequence")
    func controlBlock() throws {
        let pid = getpid()
        let writer = try #require(ControlBlockWriter(pid: pid))
        defer { writer.remove() }
        let center = OverlayCenter(game: OverlayGame(id: "g", name: "G", pid: pid), store: scratchStore(), soon: [])
        center.hudChanged = { writer.write($0) }
        center.set(.hud, HUDLevel.mini.rawValue)
        let block = writer.read()
        #expect(block.magic == FG_CONTROL_MAGIC)
        #expect(block.hud_level == 1)
        #expect(block.sequence % 2 == 0 && block.sequence > 0)
        #expect(ControlBlockWriter.string(block.hotkey) == "⌥C")
        center.setOpen(true)
        #expect(writer.read().menu_open == 1)
    }

    // MARK: Profile

    @Test("A change marks the profile modified, ⌘S saves it")
    func profile() throws {
        let store = scratchStore()
        let center = OverlayCenter(game: game, store: store, soon: [])
        #expect(!center.profile.isModified)
        center.set(.frameCap, FrameCap.fps40.rawValue)
        #expect(center.profile.isModified)
        #expect(center.handle(.save, by: .keyboard) == .save)
        #expect(!center.profile.isModified)
        #expect(store.profile(for: game.id)?.frameCap == .fps40)
        center.set(.frameCap, FrameCap.fps60.rawValue)
        center.set(.frameCap, FrameCap.fps40.rawValue)
        #expect(!center.profile.isModified)
    }

    @Test("A protected game saves its profile; without consent it never turns Cartouche Engine on")
    func protectedSaves() {
        let store = scratchStore()
        let center = OverlayCenter(game: protectedGame, store: store, soon: [])
        center.set(.hud, 1)
        center.save()
        #expect(store.profile(for: protectedGame.id)?.hud == .mini)
        #expect(store.profile(for: protectedGame.id)?.sharpening == nil)
        #expect(center.restricted)
    }

    // MARK: Dependent controls

    @Test("Upscaling off disables scale, sharpness and anti-aliasing, values kept")
    func upscalingOff() {
        var c = OverlayContext(game: game)
        c.settings.upscale = .off
        c.settings.renderScale = 72
        let rows = OverlayLayout.rows(.upscaling, c)
        for id in [OverlayRowID.upScale, .upSharpness, .upAntialias] {
            guard case .disabled = rows.first(where: { $0.id == id })?.state else { Issue.record("\(id) enabled"); continue }
        }
        #expect(c.settings.renderScale == 72)
        c.settings.upscale = .spatial
        #expect(OverlayLayout.rows(.upscaling, c).allSatisfy { $0.state == .normal })
        c.settings.upscale = .temporal
        #expect(OverlayLayout.rows(.upscaling, c).first { $0.id == .upAntialias }?.state != .normal)
    }

    @Test("Frame generation off disables its limit, compute and protection")
    func frameGenOff() {
        var c = OverlayContext(game: game, soon: [])
        c.settings.frameGen = .off
        let rows = OverlayLayout.rows(.frameGeneration, c)
        #expect(rows.filter { $0.state != .normal }.map(\.id) == [.fgCap, .fgEngine, .fgProtect])
        #expect(rows.first { $0.id == .fgCap }?.help == "Choisissez ×2 ou ×4 d’abord")
    }

    @Test("Temporal only for DLSS games")
    func temporalOnlyDLSS() {
        var noDLSS = game
        noDLSS.dlss = false
        #expect(OverlayContext(game: noDLSS).upscaleOptions == ["Non", "Cartouche"])
        #expect(OverlayContext(game: game).upscaleOptions == ["Non", "Cartouche", "DLSS"])
        #expect(OverlaySettings().fitted(dlss: false).upscale == .spatial)
    }

    // MARK: Bientôt

    @Test("Frame generation is « Bientôt » by default")
    func soonDefaults() {
        let d = scratchDefaults()
        #expect(OverlayFeature.soon(d) == [.frameGeneration, .capture])
        d.set(false, forKey: OverlayFeature.defaultsPrefix + "capture")
        d.set(false, forKey: OverlayFeature.defaultsPrefix + "frameGeneration")
        d.set(true, forKey: OverlayFeature.defaultsPrefix + "controller")
        #expect(OverlayFeature.soon(d) == [.controller])
        #expect(OverlayLayout.blocks(.capture, OverlayContext(game: game)) == [.soon(.capture)])
        let c = OverlayContext(game: game)
        #expect(OverlayLayout.blocks(.frameGeneration, c) == [.soon(.frameGeneration)])
        #expect(OverlayLayout.rows(.performance, c).first { $0.id == .perfFrameGen }?.control == .soon)
    }

    @Test("« Bientôt » wins over the anti-cheat lock")
    func soonOverAntiCheat() {
        let c = OverlayContext(game: protectedGame)
        #expect(!c.isLocked(.frameGeneration))
        #expect(OverlayLayout.blocks(.frameGeneration, c) == [.soon(.frameGeneration)])
        #expect(!c.isLocked(.upscaling), "the layer's DLSS needs no consent")
        #expect(OverlayContext(game: protectedNoDLSS).isLocked(.upscaling))
    }

    // MARK: Anti-cheat

    @Test("A protected game's launch carries none of the library's variables")
    func protectedLaunch() {
        let existing = ["CARTOUCHE_FRAMEGEN": "1", "CARTOUCHE_OVERLAY": "std", "WINEMSYNC": "1"]
        var s = OverlaySettings()
        s.hud = .standard
        let metal: Set<AdvancedOption> = [.dlss, .metalHUD]
        let env = OverlayLaunch.environment(s, supported: metal, protected: true, existing: existing)
        #expect(env["CARTOUCHE_FRAMEGEN"] == nil && env["CARTOUCHE_OVERLAY"] == nil)
        #expect(env["WINEMSYNC"] == "1")
        #expect(OverlayLaunch.environment(s, supported: metal, protected: false, existing: [:])["CARTOUCHE_OVERLAY"] == "std")
        s.upscale = .spatial
        #expect(OverlayLaunch.environment(s, supported: metal, protected: false, existing: [:])["CARTOUCHE_FRAMEGEN_TEMPORAL"] == "off")
        s.upscale = .temporal
        #expect(OverlayLaunch.environment(s, supported: metal, protected: false, existing: ["CARTOUCHE_FRAMEGEN_TEMPORAL": "off"])["CARTOUCHE_FRAMEGEN_TEMPORAL"] == nil)
        #expect(GameSetupResolver.isAllowed(name: "CARTOUCHE_OVERLAY", value: "mini"))
    }

    @Test("Locked rows show a lock and the reason")
    func lockedRows() {
        var c = OverlayContext(game: protectedGame, soon: [])
        c.live.metrics = metrics()
        let rows = OverlayLayout.rows(.performance, c)
        for id in [OverlayRowID.perfFrameGen, .perfCap] {
            guard case .locked(let why)? = rows.first(where: { $0.id == id })?.state else { Issue.record("\(id) not locked"); continue }
            #expect(!why.isEmpty)
        }
        #expect(rows.first { $0.id == .perfFrameGen }?.help == "Moteur Cartouche à activer sur la page du jeu")
        #expect(rows.first { $0.id == .perfUpscale }?.control == .segment(["Non", "DLSS"], .upscaleBase))
        #expect(OverlayLayout.rows(.performance, OverlayContext(game: protectedNoDLSS, soon: [])).first { $0.id == .perfUpscale }?.help
                == "Moteur Cartouche à activer sur la page du jeu")
        #expect(!OverlayLayout.rows(.display, c).contains { $0.id == .hideMetalHUD })
        c.soon = [.frameGeneration]
        #expect(OverlayLayout.rows(.performance, c).first { $0.id == .perfFrameGen }?.control == .soon)
    }

    @Test("A locked tab shows the reason and « Apps lourdes › Voir »")
    func lockedTab() {
        let c = OverlayContext(game: protectedNoDLSS, soon: [])
        let blocks = OverlayLayout.blocks(.upscaling, c)
        #expect(blocks.first == .empty(symbol: "lock", title: "Moteur Cartouche à activer sur la page du jeu", action: nil))
        let rows = OverlayLayout.rows(.upscaling, c)
        #expect(rows.map(\.title) == ["Apps lourdes"])
        #expect(rows.first?.control == .button("Voir", prominent: false))
    }

    @Test("Frames counted from outside: 60 fps and « 16,7 » ms")
    func externalCounter() throws {
        let counter = ExternalFrameCounter()
        for i in 0...120 { counter.recordLocked(100 + Double(i) / 60) }
        let m = try #require(counter.metrics(now: 102))
        #expect(abs(m.presentedFPS - 60) <= 1)
        #expect(OverlayFormat.decimal(m.frameMs) == "16,7")
        #expect(m.external && m.realFPS == nil && m.latencyMs == nil)
    }

    @Test("Without Screen Recording: dashes and « Mesurer les FPS »")
    func withoutScreenRecording() {
        var c = OverlayContext(game: protectedGame)
        c.live.captureAllowed = false
        let rows = OverlayLayout.rows(.performance, c)
        #expect(rows.first?.title == "Mesurer les FPS")
        #expect(rows.first?.control == .button("Autoriser…", prominent: true))
        #expect(!c.framesKnown)
    }

    @Test("A refused « Autoriser… » says so instead of staying silent")
    func deniedCaptureToast() {
        let center = OverlayCenter(game: protectedGame, store: scratchStore(), soon: [])
        center.live.captureAllowed = false
        center.actions.requestCapture = { false }
        center.run(.allowCapture)
        #expect(!center.live.captureAllowed)
        #expect(center.toasts.last?.text == ot("Screen Recording Not Allowed"))
    }

    @Test("A counter that found no window yet is retried, not kept dead")
    func counterRetriesAfterMiss() async {
        let controller = OverlayController(hotkeys: FakeRegistrar(), defaults: scratchDefaults())
        var made = 0
        let first = FakeCounter()
        first.startResult = false
        controller.makeCounter = { made += 1; return made == 1 ? first : FakeCounter() }
        await controller.ensureCounter(pid: protectedGame.pid, allowed: true)?.value
        #expect(first.starts == 1)
        #expect(controller.ensureCounter(pid: protectedGame.pid, allowed: true) == nil)
        controller.counterRetryAt = .distantPast
        await controller.ensureCounter(pid: protectedGame.pid, allowed: true)?.value
        #expect(made == 2)
    }

    @Test("A stream that stops is replaced")
    func deadCounterReplaced() async {
        let controller = OverlayController(hotkeys: FakeRegistrar(), defaults: scratchDefaults())
        var made = 0
        let first = FakeCounter()
        controller.makeCounter = { made += 1; return made == 1 ? first : FakeCounter() }
        await controller.ensureCounter(pid: protectedGame.pid, allowed: true)?.value
        #expect(first.starts == 1 && made == 1)
        first.dead = true
        await controller.ensureCounter(pid: protectedGame.pid, allowed: true)?.value
        #expect(made == 2)
    }

    // MARK: Navigation

    @Test("Keyboard: → ↓ ↓ → esc")
    func keyboardPath() {
        let center = OverlayCenter(game: game, store: scratchStore(), soon: [])
        let before = center.settings.renderScale
        _ = center.handle(.right, by: .keyboard)
        #expect(center.nav.section == .upscaling)
        _ = center.handle(.down, by: .keyboard)
        #expect(center.nav.zone == .content && center.nav.row == 0)
        _ = center.handle(.down, by: .keyboard)
        #expect(center.nav.row == 1 && center.rows[1].id == .upScale)
        _ = center.handle(.right, by: .keyboard)
        #expect(center.settings.renderScale == before + 2)
        _ = center.handle(.escape, by: .keyboard)
        #expect(center.nav.zone == .tabs)
        #expect(center.handle(.escape, by: .keyboard) == .close)
    }

    @Test("Controller: RB, A, A, Y")
    func controllerPath() {
        let store = scratchStore()
        let center = OverlayCenter(game: game, store: store, soon: [])
        _ = center.handle(.tab, by: .controller)
        #expect(center.nav.section == .upscaling)
        let mode = center.settings.upscale
        _ = center.handle(.enter, by: .controller)
        _ = center.handle(.enter, by: .controller)
        #expect(center.settings.upscale != mode)
        _ = center.handle(.save, by: .controller)
        #expect(store.profile(for: game.id)?.upscale == center.settings.upscale)
        #expect(center.nav.input == .controller)
    }

    @Test("Key help shows after a key press, never with the mouse")
    func keyHelp() {
        let center = OverlayCenter(game: game, store: scratchStore(), soon: [])
        #expect(!center.nav.showsKeyHelp)
        _ = center.handle(.down, by: .keyboard)
        #expect(center.nav.showsKeyHelp)
        center.select(.display)
        #expect(!center.nav.showsKeyHelp)
    }

    @Test("Apps: Pause then Reprendre, Quitter then Confirmer")
    func appActions() {
        let center = OverlayCenter(game: game, store: scratchStore(), soon: [])
        var done: [ResourceAction] = []
        center.actions.appAction = { _, a in done.append(a) }
        center.live.apps = [OverlayApp(pid: 7, name: "Google Chrome", cpu: 30, gpu: 6, memoryGB: 3.1)]
        center.appAction(7, sub: 0)
        #expect(center.live.apps[0].paused)
        center.appAction(7, sub: 1)
        #expect(center.nav.armedApp == 7 && done == [.pause])
        #expect(!center.clickOutside())
        #expect(center.nav.armedApp == nil)
        center.appAction(7, sub: 1)
        center.appAction(7, sub: 1)
        #expect(done == [.pause, .quit])
        #expect(center.live.apps.isEmpty)
    }

    @Test("Verdict: other apps, cap, GPU")
    func verdict() {
        var c = OverlayContext(game: game, threshold: 40)
        c.live.metrics = metrics()
        c.live.apps = [OverlayApp(pid: 7, name: "Google Chrome", cpu: 30, gpu: 6, memoryGB: 3.1)]
        c.live.othersCPU = 55
        #expect(OverlayLayout.verdict(c).title == "D’autres apps ralentissent le jeu")
        #expect(OverlayLayout.verdict(c).detail == "Google Chrome : 30\u{202F}% du CPU")
        c.live.othersCPU = 10
        #expect(OverlayLayout.verdict(c).title == "Aucun problème")
        c.live.metrics?.realFPS = 59.6
        #expect(OverlayLayout.verdict(c).title == "Limité à 60\u{202F}FPS")
        c.settings.frameCap = .none
        c.live.metrics?.gpuPercent = 99
        #expect(OverlayLayout.verdict(c).title == "Limité par le GPU (99\u{202F}%)")
        #expect(OverlayLayout.verdict(c).control == .button("Passer à 58\u{202F}%", prominent: true))
    }

    // MARK: Copy

    @Test("Every overlay string has its French")
    func frenchCopy() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let catalog = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appending(
            path: "Sources/NotProtonApp/Resources/Localization/Overlay.xcstrings"))) as? [String: Any]
        let strings = try #require(catalog?["strings"] as? [String: Any])
        let sources = try FileManager.default.contentsOfDirectory(at: root.appending(path: "Sources/NotProtonApp/Overlay"),
                                                                  includingPropertiesForKeys: nil)
        let pattern = #/ot\("([^"]*)"\)/#
        var keys: Set<String> = []
        for file in sources {
            for match in try String(contentsOf: file, encoding: .utf8).matches(of: pattern) { keys.insert(String(match.1)) }
        }
        #expect(keys.count > 100)
        #expect(keys.subtracting(strings.keys).isEmpty, "no French for \(keys.subtracting(strings.keys))")
        #expect(ot("1% Low") == "1\u{202F}% low")
        #expect(String(format: ot("Rendered at %@"), OverlayFormat.percent(67)) == "Rendu à 67\u{202F}%")
        for key in keys {
            let fr = ((strings[key] as? [String: Any])?["localizations"] as? [String: Any])?["fr"] as? [String: Any]
            #expect(((fr?["stringUnit"] as? [String: Any])?["value"] as? String)?.isEmpty == false, "no French for \(key)")
        }
    }

    @Test("English shows no French")
    func englishCopy() {
        OverlayText.use(language: "en")
        defer { OverlayText.use(language: "fr") }
        let french = ["é", "è", "à", "ù", "ç", "ê", "â", "î", "ô", "û", "’", "«", " du ", " de ", " le ", " la ", " les ", " des ", "Bientôt"]
        var shown = OverlaySection.allCases.flatMap { [$0.title, $0.short] }
        var c = OverlayContext(game: game, soon: [])
        c.live.metrics = metrics()
        for section in OverlaySection.allCases {
            for row in OverlayLayout.rows(section, c) {
                shown.append(row.title)
                if let detail = row.detail { shown.append(detail) }
                if let help = row.help { shown.append(help) }
                if case .segment(let options, _) = row.control { shown += options }
                if case .button(let label, _) = row.control { shown.append(label) }
            }
        }
        shown += [ot("Approx. 1% low"), ot("Percent of game GPU"), ot("to confirm"), ot("to resume"), ot("Take"), ot("Save Clip"),
                  ot("Coming Soon"), ot("Waiting for the game"), ot("Profile Modified"), ot("Quit Game")]
        for text in shown {
            #expect(!french.contains { text.contains($0) }, "French in English: \(text)")
        }
        #expect(ot("Approx. 1% low") == "1% Low ≈")
        #expect(ot("Take") == "Capture")
        #expect(ot("Turned Off") == "Off")
        #expect(OverlaySection.upscaling.title == "Upscaling")
    }
}
