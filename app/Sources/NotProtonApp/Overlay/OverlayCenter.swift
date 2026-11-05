import AppKit
import Foundation
import Observation

struct OverlayToast: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var undo: Bool
}

// What the menu asks of the rest of the app; tests swap each one
@MainActor
struct OverlayActions {
    var quitGame: (OverlayGame) -> Void = { game in
        NSRunningApplication(processIdentifier: game.pid)?.terminate()
    }
    var appAction: (pid_t, ResourceAction) -> Void = { _, _ in }
    var setThreshold: (Int) -> Void = { _ in }
    var setResumeApps: (Bool) -> Void = { _ in }
    var openPowerSettings: () -> Void = {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension") { NSWorkspace.shared.open(url) }
    }
    // The only Screen Recording request: « Autoriser… » of a protected game
    var requestCapture: () -> Bool = { ExternalFrameCounter.request() }
    var screenshot: (OverlayGame) async -> Bool = { _ in false }
    var rumble: () -> Void = {}
    var recordShortcut: () -> Void = {}
    // Writes the profile's launch variables into the game's setup, for its next launch
    var applyLaunch: (OverlayGame, OverlaySettings) -> Void = { _, _ in }
}

@MainActor
@Observable
final class OverlayCenter {
    private(set) var game: OverlayGame
    var profile: OverlayProfile
    var nav = OverlayNavigation()
    var live = OverlayLive()
    var soon: Set<OverlayFeature>
    var macOpen = false
    var notes: String {
        didSet { if notes != oldValue { try? store.saveNotes(notes, for: game.id) } }
    }
    var threshold = 70
    var hotkey = HotkeyCombo.optionC.label
    var hudHotkey = HotkeyCombo.optionShiftC.label
    var recordingShortcut = false
    private(set) var isOpen = false
    private(set) var toasts: [OverlayToast] = []
    var replayAvailable = false
    // The game's screen, read when the menu opens
    var safeArea = OverlaySafeArea()

    @ObservationIgnored var actions = OverlayActions()
    @ObservationIgnored let store: OverlayProfileStore
    @ObservationIgnored private var undoSnapshot: OverlaySettings?
    @ObservationIgnored var hudChanged: (HUDControl) -> Void = { _ in }

    init(game: OverlayGame, store: OverlayProfileStore = .standard, soon: Set<OverlayFeature> = OverlayFeature.soon()) {
        self.game = game
        self.store = store
        self.soon = soon
        let saved = (store.profile(for: game.id) ?? OverlaySettings()).fitted(dlss: game.dlss)
        profile = OverlayProfile(saved: saved)
        notes = store.notes(for: game.id)
    }

    var settings: OverlaySettings {
        get { profile.current }
        set {
            let old = profile.current
            profile.current = newValue.fitted(dlss: game.dlss)
            if old.resumeApps != profile.current.resumeApps { actions.setResumeApps(profile.current.resumeApps) }
            if old.hud != profile.current.hud || old.corner != profile.current.corner || old.hudSize != profile.current.hudSize {
                hudChanged(hudControl)
            }
        }
    }

    var context: OverlayContext {
        OverlayContext(game: game, settings: settings, soon: soon, live: live, threshold: threshold, macOpen: macOpen,
                       armedApp: nav.armedApp, hotkey: hotkey, hudHotkey: hudHotkey, replayAvailable: replayAvailable)
    }

    var restricted: Bool { context.restricted }

    // Without our library in the game its HUD cannot draw: ours stands in, fed from outside.
    // A library already drawing in the game keeps the HUD there, so it never shows twice
    var hudOutside: Bool { !game.libraryLoaded }

    var blocks: [OverlayBlock] { OverlayLayout.blocks(nav.section, context) }
    var rows: [OverlayRow] { OverlayLayout.rows(nav.section, context) }
    var focusedRow: OverlayRow? {
        nav.zone == .content && nav.input != .pointer ? rows.indices.contains(nav.row) ? rows[nav.row] : nil : nil
    }

    var hudControl: HUDControl {
        var c = HUDControl(level: settings.hud, corner: settings.corner, scale: [100, 125, 150][settings.hudSize],
                           menuOpen: isOpen, battery: live.mac.battery, gpuWatts: live.mac.gpuWatts, hotkey: hotkey,
                           safeTop: Double(safeArea.top), screenHeight: Double(safeArea.screenHeight))
        if live.othersCPU > Double(threshold), let top = live.top {
            c.warning = String(format: ot("%1$@ uses %2$@ of the CPU"), top.name, OverlayFormat.percent(top.cpu))
        }
        return c
    }

    // MARK: Opening

    func setOpen(_ open: Bool) {
        guard open != isOpen else { return }
        isOpen = open
        nav.quitArmed = false
        nav.armedApp = nil
        recordingShortcut = false
        if open { nav.zone = .tabs }
        hudChanged(hudControl)
    }

    func clickOutside() -> Bool { nav.clickOutside() }

    // MARK: Input

    func handle(_ key: OverlayKey, by input: OverlayInput) -> OverlayEffect? {
        var s = settings
        let effect = nav.handle(key, rows: rows, settings: &s, by: input)
        if s != settings { settings = s }
        switch effect {
        case .save?: save()
        case .run(let id, let sub)?: run(id, sub: sub)
        default: break
        }
        return effect
    }

    func select(_ section: OverlaySection) { nav.go(section, by: .pointer) }

    func pointer(on row: OverlayRow) {
        nav.input = .pointer
        nav.zone = .content
        if let i = rows.firstIndex(where: { $0.id == row.id }) { nav.row = i }
    }

    func binding(_ key: SettingKey) -> Int { key.get(settings) }

    func set(_ key: SettingKey, _ value: Int) {
        var s = settings
        key.set(&s, value)
        settings = s
    }

    // MARK: Actions

    func run(_ id: OverlayRowID, sub: Int = 0) {
        switch id {
        case .macFold: macOpen.toggle()
        case .verdict: verdictAction()
        case .heavyApps: select(.resources)
        case .power: actions.openPowerSettings()
        case .measure, .allowCapture:
            let allowed = actions.requestCapture() || live.captureAllowed
            if !allowed { toast(ot("Screen Recording Not Allowed")) }
            live.captureAllowed = allowed
        case .threshold:
            threshold = sub
            actions.setThreshold(sub)
        case .app(let pid): appAction(pid, sub: sub)
        case .screenshot:
            let game = game
            Task { if await actions.screenshot(game) { toast(ot("Screenshot saved in Pictures › Cartouche")) } }
        case .pad: actions.rumble()
        case .shortcuts:
            recordingShortcut = true
            toast(ot("Press the new combination"))
            actions.recordShortcut()
        default: break
        }
    }

    private func verdictAction() {
        let row = OverlayLayout.verdict(context)
        guard case .button = row.control else { return }
        if live.othersCPU > Double(threshold) {
            select(.resources)
        } else if settings.upscale == .off {
            undoSnapshot = settings
            var s = settings
            s.upscale = game.dlss ? .temporal : .spatial
            s.renderScale = 67
            settings = s
            let kind = game.dlss ? ot("temporal kind") : ot("spatial kind")
            toast(String(format: ot("%1$@ upscaling turned on at %2$@"), kind, OverlayFormat.percent(67)), undo: true)
        } else {
            undoSnapshot = settings
            set(.renderScale, 58)
            toast(String(format: ot("Render scale set to %@"), OverlayFormat.percent(58)), undo: true)
        }
    }

    func undo() {
        guard let snapshot = undoSnapshot else { return }
        settings = snapshot
        undoSnapshot = nil
    }

    func appAction(_ pid: pid_t, sub: Int) {
        guard let app = live.apps.first(where: { $0.pid == pid }), !app.system else { return }
        if sub == 0 {
            actions.appAction(pid, app.paused ? .resume : .pause)
            if let i = live.apps.firstIndex(where: { $0.pid == pid }) { live.apps[i].paused.toggle() }
            nav.armedApp = nil
        } else if nav.armedApp != pid {
            nav.armedApp = pid
        } else {
            actions.appAction(pid, .quit)
            live.apps.removeAll { $0.pid == pid }
            nav.armedApp = nil
            nav.sub = 0
            toast(String(format: ot("%@ was quit"), app.name))
        }
    }

    func quitPressed() -> Bool {
        if nav.quitArmed {
            nav.quitArmed = false
            actions.quitGame(game)
            return true
        }
        nav.quitArmed = true
        return false
    }

    // Saved for any game: the launch keeps our code out without Cartouche Sharpening
    func save() {
        do {
            try store.save(settings, for: game.id)
            profile.markSaved()
            actions.applyLaunch(game, settings)
            toast(ot("Profile saved"))
        } catch {
            AppLog.note("overlay profile not saved: \(error.localizedDescription)")
        }
    }

    func toast(_ text: String, undo: Bool = false) {
        let t = OverlayToast(text: text, undo: undo)
        toasts.append(t)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(undo ? 4 : 2.4))
            self?.toasts.removeAll { $0.id == t.id }
        }
    }

    func dismissToast(_ id: UUID) { toasts.removeAll { $0.id == id } }
}
