import AppKit
import SwiftUI
import Testing

@testable import NotProtonApp

// T17: toggling Cartouche Sharpening on a protected game must not close the game panel.
// The tests host the real LibraryWindow, flip the switch as a user does, and dismiss
// the consent alert each way: Turn On, Cancel, Escape — panel docked and floating.
@MainActor
@Suite("Sharpening consent keeps the panel open", .serialized)
struct SharpeningPanelBugTests {

    // Elden Ring is the protected game: the compat fixture reports Easy Anti-Cheat for it
    struct Scene {
        let fixture: SteamFixture
        let scratch = ScratchDefaults()
        let model: LibraryModel
        let compat: CompatibilityModel
        let setup: SteamSetup
        let actions: GameActionRunner

        @MainActor
        init(_ label: String) async throws {
            fixture = try SteamFixture(label)
            try fixture.writeExport()
            try fixture.addArt([1_245_620])
            model = libraryModel(fixture, defaults: scratch)
            // The installer game lives in the fixture's games location, like a real install
            let folder = model.installsFolder.appending(path: SharpeningPanelBugTests.installedRecord.id, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try InstalledGames.save(SharpeningPanelBugTests.installedRecord, in: GameFolder(root: folder))
            compat = try await fixtureCompat(fixture.root, defaults: scratch)
            var steps = SteamSetup.Steps()
            steps.brewPath = { "/opt/homebrew/bin/brew" }
            setup = SteamSetup(steps: steps, defaults: scratch.defaults)
            actions = GameActionRunner(model: model, open: { _ in })
            await model.load()
            let build = RunnerManifest.current().builds.first { $0.origin == .cartouche }
            if let build {
                model.runners = [Runner(id: build.id, kind: .wineBuild, version: build.version,
                                        displayVersion: build.displayVersion, flavors: [.rosetta],
                                        state: .ready, build: nil, source: nil, isInstalled: true)]
                model.backendAvailability = BackendAvailability(d3dMetalRunners: [build.id], crossOverWine: [build.id])
            }
            model.antiCheat = { $0.steamAppID == 1_245_620 ? "Easy Anti-Cheat" : nil }
            await compat.openGame(appID: 1_245_620)
        }

        @MainActor
        func window() -> some View {
            LibraryWindow(model: model, compat: compat, steamSetup: setup, actions: actions)
                .environment(\.covers, fixture.covers())
                .environment(\.advancedOpen, true)
                .environment(\.glassMode, .classic)
        }
    }

    // MARK: Driving the hosted window

    // Every AppKit switch the window's view tree holds
    private func switches(in view: NSView) -> [NSView] {
        var found: [NSView] = []
        func walk(_ v: NSView) {
            if String(describing: type(of: v)) == "PlatformSwitch" { found.append(v) }
            for sub in v.subviews { walk(sub) }
        }
        walk(view)
        return found
    }

    private func buttons(in view: NSView) -> [NSButton] {
        var found: [NSButton] = []
        func walk(_ v: NSView) {
            if let b = v as? NSButton { found.append(b) }
            for sub in v.subviews { walk(sub) }
        }
        walk(view)
        return found
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        var found: [NSScrollView] = []
        func walk(_ v: NSView) {
            if let scroll = v as? NSScrollView { found.append(scroll) }
            for sub in v.subviews { walk(sub) }
        }
        walk(view)
        return found
    }

    private func windowFrame(of view: NSView) -> CGRect {
        view.convert(view.bounds, to: nil)
    }

    // The panel's own scroll view: the one sitting in the panel column on the right
    private func panelScroll(in window: NSWindow) -> NSScrollView? {
        scrollViews(in: window.contentView!).first {
            windowFrame(of: $0).width == WindowLayout(width: window.contentLayoutRect.width, sidebar: true).panel
        }
    }

    // The switch of the Image section's first row: the topmost switch in the panel
    private func sharpeningSwitch(in window: NSWindow) -> NSView? {
        switches(in: window.contentView!)
            .filter { windowFrame(of: $0).minX > window.contentLayoutRect.width / 2 }
            .max { windowFrame(of: $0).minY < windowFrame(of: $1).minY }
    }

    private func scrollToBottom(_ scroll: NSScrollView) {
        guard let doc = scroll.documentView else { return }
        doc.scroll(NSPoint(x: 0, y: doc.bounds.height - scroll.contentView.bounds.height))
    }

    private func scrollOffset(_ scroll: NSScrollView) -> CGFloat {
        scroll.contentView.bounds.origin.y
    }

    private func sendKey(_ key: UInt16 = 53, chars: String = "\u{1b}", to window: NSWindow) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                                               timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil,
                                               characters: chars, charactersIgnoringModifiers: chars,
                                               isARepeat: false, keyCode: key)
            else { continue }
            window.sendEvent(event)
        }
    }

    private func alertWindow(host: NSWindow) -> NSWindow? {
        if let sheet = host.attachedSheet { return sheet }
        return NSApp.windows.first { $0 !== host && $0.isVisible && $0.sheetParent === host }
    }

    // Through the app's real routing: keyDown reaches the key window's key-equivalent pass
    private func sendKeyToApp(_ window: NSWindow, key: UInt16 = 53, chars: String = "\u{1b}") {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil,
                                           characters: chars, charactersIgnoringModifiers: chars,
                                           isARepeat: false, keyCode: key)
        else { return }
        NSApp.sendEvent(event)
    }

    // The consent sheet's button, e.g. "Turn On" / "Cancel": ot() gives the title in whatever
    // language a previous suite pinned, so the lookup stays true in any order
    private func alertButton(_ key: String.LocalizationValue, host: NSWindow) -> NSButton? {
        guard let alert = alertWindow(host: host), let content = alert.contentView else { return nil }
        return buttons(in: content).first { $0.title == ot(key) }
    }

    // MARK: The flow

    enum Layout { case docked, floating }

    // A sheet still up at teardown outlives its window and feeds the next lookups
    private func close(_ host: UIHost) {
        if let sheet = host.window.attachedSheet { host.window.endSheet(sheet) }
        host.close()
    }

    // Hosts the window at a width that docks (860) or floats (800) the panel,
    // picks the protected game and scrolls Avancé into view as the user does
    private func host(_ label: String, layout: Layout) async throws -> (scene: Scene, host: UIHost, scroll: NSScrollView) {
        let scene = try await Scene(label)
        // Floating needs the pick after hosting: a docked first layout marks the overlay dismissed
        if layout == .docked { scene.model.select("steam:1245620") }
        let host = UIHost(scene.window(), size: CGSize(width: layout == .docked ? 860 : 800, height: 780))
        await host.settle(1.0)
        if layout == .floating { scene.model.select("steam:1245620") }
        await host.settle(1.5)
        let scroll = try #require(panelScroll(in: host.window), "\(label): the game panel never showed")
        scrollToBottom(scroll)
        await host.settle(0.8)
        return (scene, host, scroll)
    }

    // Clicking the switch a protected game shows: the consent alert must come up
    @discardableResult
    private func askConsent(_ label: String, host: UIHost) async throws -> NSWindow {
        let target = try #require(sharpeningSwitch(in: host.window), "\(label): no sharpening switch")
        (target as? NSControl)?.performClick(nil)
        // The sheet attaches before its buttons populate; wait for a titled one
        _ = await waitFor(5) {
            alertWindow(host: host.window)?.contentView.map { content in
                buttons(in: content).contains { !$0.title.isEmpty }
            } == true
        }
        return try #require(alertWindow(host: host.window), "\(label): the consent alert did not appear")
    }

    private func sharpening(_ scene: Scene) -> Bool? {
        scene.model.profile(for: "steam:1245620").sharpening
    }

    // What the user sees: the knob's bright blob sits right of center on an ON
    // switch, left on OFF. Returns the blob's centroid X as a fraction of width.
    private func knobPosition(_ sw: NSView) -> Double? {
        guard let rep = renderedBitmap(sw), let data = rep.bitmapData else { return nil }
        let w = rep.pixelsWide, h = rep.pixelsHigh, stride = rep.bytesPerRow
        var sumX = 0, count = 0
        for y in 0..<h {
            let row = data + y * stride
            for x in 0..<w {
                let p = row + x * 4
                guard p[3] > 200, p[0] > 220, p[1] > 220, p[2] > 220 else { continue }
                sumX += x; count += 1
            }
        }
        guard count > 10 else { return nil }
        return Double(sumX) / Double(count) / Double(w)
    }

    private func switchControl(in window: NSWindow) throws -> NSControl {
        try #require(sharpeningSwitch(in: window) as? NSControl, "no sharpening switch")
    }

    // T21: the consent flow used to leave the switch's own presentation behind —
    // drawn OFF with sharpening:true stored, so one more click undid the consent.
    // What proves the fix: the control the user ends up with is a fresh one bound
    // to the written state, and what it shows always equals that state.
    @Test("Turn On leaves the switch on, drawn on", arguments: [Layout.docked, .floating])
    func turnOnSwitchState(layout: Layout) async throws {
        let (scene, host, _) = try await host("t21-on-\(layout)", layout: layout)
        defer { scene.fixture.remove(); close(host) }
        let idle = try switchControl(in: host.window)
        #expect(idle.integerValue == 0)
        try await askConsent("t21-on", host: host)
        let pending = try switchControl(in: host.window)
        #expect(pending.integerValue == 0, "consent pending: the switch shows off")
        #expect(knobPosition(pending).map { $0 < 0.5 } ?? false)
        try #require(alertButton("Turn On", host: host.window)).performClick(nil)
        #expect(await waitFor(5) { host.window.attachedSheet == nil })
        await host.settle(0.8)
        let on = try switchControl(in: host.window)
        #expect(sharpening(scene) == true)
        #expect(on.integerValue == 1)
        #expect(knobPosition(on).map { $0 > 0.5 } ?? false)
        // The stale-presentation bug rode on the reused control; a fresh one cannot drift
        #expect(on !== pending && on !== idle, "the switch keeps the control the rejected click left")
    }

    @Test("Cancel leaves the switch off, drawn off", arguments: [Layout.docked, .floating])
    func cancelSwitchState(layout: Layout) async throws {
        let (scene, host, _) = try await host("t21-cancel-\(layout)", layout: layout)
        defer { scene.fixture.remove(); close(host) }
        try await askConsent("t21-cancel", host: host)
        let pending = try switchControl(in: host.window)
        try #require(alertButton("Cancel", host: host.window)).performClick(nil)
        #expect(await waitFor(5) { host.window.attachedSheet == nil })
        await host.settle(0.8)
        let off = try switchControl(in: host.window)
        #expect(sharpening(scene) == nil)
        #expect(off.integerValue == 0)
        #expect(knobPosition(off).map { $0 < 0.5 } ?? false)
        #expect(off !== pending, "a cancelled consent must not inherit the clicked state")
    }

    // No alert anywhere: a clean game answers the switch directly, on and off
    @Test("Unprotected game's switch follows its clicks", arguments: [Layout.docked, .floating])
    func unprotectedSwitchState(layout: Layout) async throws {
        let scene = try await Scene("t21-open-\(layout)")
        defer { scene.fixture.remove() }
        if layout == .docked { scene.model.select("steam:730") }
        let host = UIHost(scene.window(), size: CGSize(width: layout == .docked ? 860 : 800, height: 780))
        defer { close(host) }
        await host.settle(1.0)
        if layout == .floating { scene.model.select("steam:730") }
        await host.settle(1.5)
        let scroll = try #require(panelScroll(in: host.window), "the game panel never showed")
        scrollToBottom(scroll)
        await host.settle(0.8)

        let on = try switchControl(in: host.window)
        #expect(scene.model.antiCheatName(for: try #require(scene.model.game("steam:730"))) == nil)
        #expect(on.integerValue == 1, "an unprotected game starts with our engine on")
        #expect(knobPosition(on).map { $0 > 0.5 } ?? false)

        on.performClick(nil)
        await host.settle(0.8)
        #expect(host.window.attachedSheet == nil, "no consent asked of a clean game")
        #expect(scene.model.profile(for: "steam:730").sharpening == false)
        let off = try switchControl(in: host.window)
        #expect(off.integerValue == 0)
        #expect(knobPosition(off).map { $0 < 0.5 } ?? false)

        off.performClick(nil)
        await host.settle(0.8)
        #expect(host.window.attachedSheet == nil)
        #expect(scene.model.profile(for: "steam:730").sharpening == nil)
        let back = try switchControl(in: host.window)
        #expect(back.integerValue == 1)
        #expect(knobPosition(back).map { $0 > 0.5 } ?? false)
    }

    // The path the bug made dangerous: after a granted consent, one more click
    // must turn the engine off — no alert, real state and shown state together
    @Test("Switching a consented game back off needs no alert", arguments: [Layout.docked, .floating])
    func consentThenOff(layout: Layout) async throws {
        let (scene, host, _) = try await host("t21-off-\(layout)", layout: layout)
        defer { scene.fixture.remove(); close(host) }
        try await askConsent("t21-off", host: host)
        try #require(alertButton("Turn On", host: host.window)).performClick(nil)
        #expect(await waitFor(5) { host.window.attachedSheet == nil })
        await host.settle(0.8)
        try #require(sharpening(scene) == true)

        try switchControl(in: host.window).performClick(nil)
        await host.settle(0.8)
        #expect(host.window.attachedSheet == nil, "turning off asks nothing")
        #expect(sharpening(scene) == nil)
        let off = try switchControl(in: host.window)
        #expect(off.integerValue == 0)
        #expect(knobPosition(off).map { $0 < 0.5 } ?? false)
    }

    // MARK: Tests

    @Test("Turn On keeps the panel open, sharpening on", arguments: [Layout.docked, .floating])
    func turnOn(layout: Layout) async throws {
        let (scene, host, scroll) = try await host("t17-on-\(layout)", layout: layout)
        defer { scene.fixture.remove(); close(host) }
        let before = scrollOffset(scroll)
        try await askConsent("t17-on", host: host)
        try #require(alertButton("Turn On", host: host.window)).performClick(nil)
        #expect(await waitFor(5) { host.window.attachedSheet == nil })
        #expect(panelScroll(in: host.window) != nil)
        #expect(panelScroll(in: host.window).map(scrollOffset) == before)
        #expect(sharpeningSwitch(in: host.window) != nil)
        #expect(sharpening(scene) == true)
    }

    @Test("Cancel keeps the panel open, sharpening stays off", arguments: [Layout.docked, .floating])
    func cancel(layout: Layout) async throws {
        let (scene, host, scroll) = try await host("t17-cancel-\(layout)", layout: layout)
        defer { scene.fixture.remove(); close(host) }
        let before = scrollOffset(scroll)
        try await askConsent("t17-cancel", host: host)
        try #require(alertButton("Cancel", host: host.window)).performClick(nil)
        #expect(await waitFor(5) { host.window.attachedSheet == nil })
        #expect(panelScroll(in: host.window) != nil)
        #expect(panelScroll(in: host.window).map(scrollOffset) == before)
        #expect(sharpening(scene) == nil)
    }

    // The reported path: Escape while the consent sheet is up. Floating leaves the main
    // window key, so the key equivalent search finds the overlay's close button — the
    // reported bug. Docked has no such button; the sheet itself gets the key.
    @Test("Escape dismisses only the alert", arguments: [Layout.docked, .floating])
    func escape(layout: Layout) async throws {
        let (scene, host, scroll) = try await host("t17-esc-\(layout)", layout: layout)
        defer { scene.fixture.remove(); close(host) }
        let before = scrollOffset(scroll)
        let alert = try await askConsent("t17-esc", host: host)
        sendKey(to: layout == .floating ? host.window : alert)
        #expect(await waitFor(5) { host.window.attachedSheet == nil })
        #expect(panelScroll(in: host.window) != nil)
        #expect(panelScroll(in: host.window).map(scrollOffset) == before)
        #expect(sharpeningSwitch(in: host.window) != nil)
        #expect(sharpening(scene) == nil)
    }

    @Test("Switching off without an alert keeps the panel open", arguments: [Layout.docked, .floating])
    func offWithoutAlert(layout: Layout) async throws {
        let (scene, host, scroll) = try await host("t17-off-\(layout)", layout: layout)
        defer { scene.fixture.remove(); close(host) }
        let before = scrollOffset(scroll)
        try await askConsent("t17-off", host: host)
        try #require(alertButton("Turn On", host: host.window)).performClick(nil)
        #expect(await waitFor(5) { host.window.attachedSheet == nil })
        await host.settle(0.8)
        let off = try #require(sharpeningSwitch(in: host.window), "switch gone after Turn On")
        (off as? NSControl)?.performClick(nil)
        await host.settle(0.8)
        #expect(host.window.attachedSheet == nil)
        #expect(panelScroll(in: host.window) != nil)
        #expect(panelScroll(in: host.window).map(scrollOffset) == before)
        #expect(sharpening(scene) == nil)
    }

    // The floating close button keeps its Escape shortcut: with no sheet up, Escape still hides the overlay
    @Test("Escape still hides the floating panel with no sheet up")
    func escapeStillClosesFloating() async throws {
        let (scene, host, _) = try await host("t17-esc-close", layout: .floating)
        defer { scene.fixture.remove(); close(host) }
        host.window.makeKey()
        sendKeyToApp(host.window)
        #expect(await waitFor(5) { panelScroll(in: host.window) == nil })
    }

    // Every panel write on an installer game — sharpening consent, HUD mode, any toggle —
    // ends in setProfile -> setSetup -> applyInstallerSetup, which re-lists the installs
    // folder through showInstalledGames. That rescan used to remove installer games from
    // otherGames before adding them back: the rebuild in between found no
    // "installer:cobalt-street" in gamesByID, keepSelectionVisible cleared selectedGameID,
    // and the panel closed (reproduced in the real app on Cobalt Street).
    private static let installedRecord = InstalledGame(
        id: "cobalt-street", name: "Cobalt Street", appID: 1_114_150, gogID: nil,
        runnerID: "wine-crossover-26.3.0-2", graphics: "d3dmetal",
        wineVersion: nil, wineRunnerKind: nil,
        prefix: "/nonexistent/cobalt-street/pfx", exe: "/nonexistent/Cobalt Street.exe",
        installedAt: Date(), installerFolder: "/nonexistent",
        redistributables: [], gameFolder: nil, verification: nil)

    @Test("Re-listing installer games keeps the selection")
    func rescanKeepsSelection() async throws {
        let scene = try await Scene("t17-rescan")
        defer { scene.fixture.remove() }
        scene.model.showInstalledGames([Self.installedRecord])
        scene.model.selection = .source(.installer)
        scene.model.select("installer:cobalt-street")
        #expect(scene.model.selectedGameID == "installer:cobalt-street")
        #expect(scene.model.selectedGame != nil)
        scene.model.showInstalledGames([Self.installedRecord])
        #expect(scene.model.selectedGameID == "installer:cobalt-street")
    }

    @Test("A profile write on an installer game keeps the panel open", arguments: [Layout.docked, .floating])
    func installerWriteKeepsPanel(layout: Layout) async throws {
        let scene = try await Scene("t17-inst-\(layout)")
        defer { scene.fixture.remove() }
        scene.model.showInstalledGames([Self.installedRecord])
        if layout == .docked {
            scene.model.selection = .source(.installer)
            scene.model.select("installer:cobalt-street")
        }
        let host = UIHost(scene.window(), size: CGSize(width: layout == .docked ? 860 : 800, height: 780))
        defer { close(host) }
        await host.settle(1.0)
        if layout == .floating {
            // The dock->float flip dismisses the overlay for the game picked at load;
            // navigating to the source then picking Cobalt Street is what shows it again
            scene.model.selection = .source(.installer)
            scene.model.select("installer:cobalt-street")
        }
        await host.settle(1.5)
        if panelScroll(in: host.window) == nil {
            Issue.record("\(layout) setup — id:\(scene.model.selectedGameID ?? "nil") game:\(scene.model.selectedGame?.id ?? "nil") screen:\(scene.model.screen) showPanel:\(scene.model.showPanel) allGames:\(scene.model.allGames.map(\.id))")
        }
        try #require(panelScroll(in: host.window) != nil, "\(layout): the game panel never showed")

        // What applyInstallerSetup does after rewriting the game's launcher
        scene.model.showInstalledGames([Self.installedRecord])
        await host.settle(0.8)

        #expect(scene.model.selectedGameID == "installer:cobalt-street")
        #expect(panelScroll(in: host.window) != nil)
    }
}
