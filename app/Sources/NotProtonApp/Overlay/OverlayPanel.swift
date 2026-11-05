import AppKit
import GameController
import SwiftUI

// A borderless panel over the game's screen or window at .screenSaver: Wine lifts a fullscreen game to
// layer 26, which .floating and .statusBar stay under (spike S1). It activates, so Wine frees the
// cursor (S2).
final class OverlayPanel: NSPanel {
    static let level = NSWindow.Level.screenSaver
    static let behavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

    convenience init(screen: NSScreen, activating: Bool = true) {
        self.init(frame: screen.frame, activating: activating)
    }

    init(frame: CGRect, activating: Bool = true) {
        super.init(contentRect: frame, styleMask: activating ? [.borderless] : [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        setFrame(frame, display: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        // Showing a panel that can hide unhides Cartouche, and its windows with it
        canHide = false
        level = Self.level
        collectionBehavior = Self.behavior
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// Activation is injected so tests count it
@MainActor
struct OverlayActivation {
    var activateSelf: () -> Void = {
        NSApp.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            // Cooperative activation refuses the first request from the background (spike S1)
            if !NSApp.isActive { NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps]) }
        }
    }
    var activateGame: (pid_t) -> Void = { pid in
        guard let game = NSRunningApplication(processIdentifier: pid) else { return }
        NSApp.yieldActivation(to: game)
        _ = game.activate(from: .current, options: [])
    }
    // Hiding Cartouche while it is still active hands the focus to the next app in line, not to the game
    var whenGameFront: (pid_t, TimeInterval, @escaping @MainActor () -> Void) -> Void = { pid, timeout, work in
        FrontWatch.when(pid: pid, timeout: timeout, work)
    }
    // Right after the close, another app taking the front is macOS's pick, never the player's: the game gets it back
    var guardFront: (pid_t, TimeInterval) -> Void = { pid, window in FrontWatch.guardGame(pid: pid, for: window) }
    var restoreGame: (pid_t) -> Void = { GameRestore.run(pid: $0) }
    // Cartouche Wine keeps the game unaware of the menu's focus, like a permission dialog, and frees the cursor
    var tellGame: (pid_t, OverlayNotice) -> Void = { pid, notice in
        DistributedNotificationCenter.default().postNotificationName(notice.name, object: String(pid), userInfo: nil, deliverImmediately: true)
    }
    // Lets the game's Wine read the notice before Cartouche takes the focus
    var settle: (@escaping @MainActor () -> Void) -> Void = { work in
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { MainActor.assumeIsolated { work() } }
    }
    var show: (NSPanel) -> Void = { $0.makeKeyAndOrderFront(nil) }
    var hide: (NSPanel) -> Void = { $0.orderOut(nil) }
    var showHUD: (NSPanel) -> Void = { $0.orderFrontRegardless() }
    // Only the panel shows: the app's other windows leave before it activates, and come back behind the game
    var hideWindows: () -> [NSWindow] = { OverlayWindows.hideAll() }
    var restoreWindows: ([NSWindow]) -> Void = { $0.forEach { $0.orderBack(nil) } }
    var bringBack: ([NSWindow]) -> Void = { $0.forEach { $0.orderFront(nil) } }
    // Sets the options, returns the ones before
    var presentation: (NSApplication.PresentationOptions) -> NSApplication.PresentationOptions = { options in
        let app = NSApplication.shared
        let before = app.presentationOptions
        app.presentationOptions = options
        return before
    }
    // « When a game starts: Hide » leaves Cartouche hidden; activating it unhides it, so it hides again after
    var appHidden: () -> Bool = { NSApp.isHidden }
    var hideApp: () -> Void = { NSApp.hide(nil) }
}

@MainActor
enum FrontWatch {
    static func when(pid: pid_t, timeout: TimeInterval, _ work: @escaping @MainActor () -> Void) {
        guard NSRunningApplication(processIdentifier: pid) != nil,
              NSWorkspace.shared.frontmostApplication?.processIdentifier != pid else { work(); return }
        var done = false
        var token: NSObjectProtocol?
        let finish: @MainActor () -> Void = {
            guard !done else { return }
            done = true
            if let token { NSWorkspace.shared.notificationCenter.removeObserver(token) }
            work()
        }
        token = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.processIdentifier == pid else { return }
            MainActor.assumeIsolated { finish() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { MainActor.assumeIsolated { finish() } }
    }

    static func guardGame(pid: pid_t, for window: TimeInterval) {
        guard let game = NSRunningApplication(processIdentifier: pid) else { return }
        let token = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard let app, app.processIdentifier != pid, app != .current else { return }
            AppLog.note("overlay: \(app.localizedName ?? "an app") took the front after the close, the game gets it back")
            _ = game.activate(options: [.activateIgnoringOtherApps])
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + window) { NSWorkspace.shared.notificationCenter.removeObserver(token) }
    }
}

enum OverlayNotice {
    case willOpen, didClose

    var name: Notification.Name {
        switch self {
        case .willOpen: Notification.Name("dev.bryann2k.cartouche.overlay.willOpen")
        case .didClose: Notification.Name("dev.bryann2k.cartouche.overlay.didClose")
        }
    }
}

enum OverlayWindows {
    // The menu bar and the Dock stay away while the menu is open; macOS wants the Dock hidden to hide the bar
    static let presentation: NSApplication.PresentationOptions = [.hideDock, .hideMenuBar]

    // The status item and the menu's own panels stay; sheets and child windows follow their parent
    static func hides(level: NSWindow.Level, visible: Bool, overlay: Bool, attached: Bool) -> Bool {
        visible && !overlay && !attached && level.rawValue < NSWindow.Level.statusBar.rawValue
    }

    // A hidden app's windows all read invisible, yet unhiding brings back the ones shown before the hide
    static func shown(hidden: Bool, windows: [NSWindow], beforeHide: [NSWindow]) -> [NSWindow] {
        (hidden ? beforeHide : windows).filter {
            hides(level: $0.level, visible: hidden || $0.isVisible, overlay: $0 is OverlayPanel, attached: $0.parent != nil || $0.sheetParent != nil)
        }
    }

    // Ordered out while hidden, a window stays out when the app unhides
    @MainActor
    static func hideAll() -> [NSWindow] {
        let app = NSApplication.shared
        let windows = shown(hidden: app.isHidden, windows: app.windows, beforeHide: beforeHide.allObjects)
        windows.forEach { $0.orderOut(nil) }
        return windows
    }

    @MainActor private static let beforeHide = NSHashTable<NSWindow>.weakObjects()

    @MainActor static let watching: NSObjectProtocol = NotificationCenter.default.addObserver(
        forName: NSApplication.willHideNotification, object: nil, queue: .main
    ) { _ in
        MainActor.assumeIsolated {
            beforeHide.removeAllObjects()
            NSApplication.shared.windows.filter(\.isVisible).forEach { beforeHide.add($0) }
        }
    }
}

// Owns the panel, the shortcut, the keyboard and controller while the menu is open, and the live numbers
@MainActor
final class OverlayController {
    static let shared = OverlayController()
    private(set) var center: OverlayCenter?
    private var panel: OverlayPanel?
    private var hudPanel: OverlayPanel?
    private var shown = false
    private var keyMonitor: Any?
    private var refresh: Task<Void, Never>?
    private var control: ControlBlockWriter?
    private var power = GPUPower()
    private var counter: (any ExternalFrameCounting)?
    var counterRetryAt = Date.distantPast
    var makeCounter: () -> any ExternalFrameCounting = { ExternalFrameCounter() }
    private var lastGPU: (seconds: Double, at: Date)?
    private let hotkeys: HotkeyRegistrar
    private let defaults: UserDefaults
    var activation = OverlayActivation()
    var resources: ResourceMonitor?
    var resolveGame: @MainActor (NSRunningApplication) -> OverlayGame? = { OverlayController.gameFromProcess($0) }
    var actions = OverlayActions()
    private(set) var registered: HotkeyCombo?
    private(set) var gameRunning = false
    private var hiddenWindows: [NSWindow] = []
    private var rehide = false
    private var fullScreen = false
    // Windows that wait for the user to come back to Cartouche: ordering them in from a fullscreen game's Space switches Spaces
    private(set) var pendingWindows: [NSWindow] = []
    private var activeObserver: NSObjectProtocol?
    private var presentationBefore: NSApplication.PresentationOptions?
    var locate: @MainActor (pid_t) -> OverlayPlacement? = { OverlayPlacement.live(pid: $0) }
    var libraryPublishes: (pid_t) -> Bool = { MetricsBlockReader.read(pid: $0) != nil }

    init(hotkeys: HotkeyRegistrar? = nil, defaults: UserDefaults = .standard) {
        let keys = hotkeys ?? CarbonHotkeys()
        self.hotkeys = keys
        self.defaults = defaults
        (keys as? CarbonHotkeys)?.fired = { [weak self] id in self?.hotkeyFired(id) }
        _ = OverlayWindows.watching
    }

    var isOpen: Bool { shown }

    // MARK: Game lifetime

    // The shortcut exists only while a game Cartouche launched runs
    func gameStarted() {
        gameRunning = true
        if let note = OverlayHotkey.othersNote(OverlayHotkey.otherInstances()) { AppLog.note(note) }
        guard registered == nil else { AppLog.note("hotkey: \(registered?.label ?? "") already registered"); return }
        registered = OverlayHotkey.register(stored: OverlayHotkey.stored(defaults), hud: OverlayHotkey.hud(defaults), with: hotkeys)
    }

    func gameEnded() {
        gameRunning = false
        hotkeys.unregisterAll()
        registered = nil
        if shown { close() }
        hudPanel?.orderOut(nil)
        hudPanel = nil
        refresh?.cancel()
        refresh = nil
        control?.remove()
        control = nil
        let counter = counter
        self.counter = nil
        Task { await counter?.stop() }
        center = nil
    }

    func hotkeyFired(_ id: UInt32) {
        if id == OverlayHotkey.hudID {
            guard let center else { return }
            center.set(.hud, (center.settings.hud.rawValue + 1) % HUDLevel.allCases.count)
            return
        }
        toggle()
    }

    func toggle() { shown ? close() : open() }

    // The game page's « Menu en jeu »: the running game Cartouche launched, whichever app is in front
    // From a game's page: that game, not the first Wine process found (explorer, a launcher)
    func openForRunningGame(id: String? = nil) {
        let games = NSWorkspace.shared.runningApplications.compactMap { self.resolveGame($0) }
        if let game = Self.pick(games, id: id) { open(game: game) }
    }

    static func pick(_ games: [OverlayGame], id: String?) -> OverlayGame? {
        id.flatMap { id in games.first { $0.id == id } } ?? games.first
    }

    // Settings changed a shortcut: a running game gets it at once
    func shortcutsChanged() {
        guard gameRunning else { return }
        registered = OverlayHotkey.register(stored: OverlayHotkey.stored(defaults), hud: OverlayHotkey.hud(defaults), with: hotkeys)
        center?.hotkey = registered?.label ?? HotkeyCombo.optionC.label
        center?.hudHotkey = OverlayHotkey.hud(defaults).label
    }

    // MARK: Open, close

    func open(game explicit: OverlayGame? = nil, screen: NSScreen? = nil) {
        guard !shown else { return }
        let front = NSWorkspace.shared.frontmostApplication
        let game = explicit ?? front.flatMap(resolveGame)
        guard let game else { return }
        let center = attach(game)
        guard let placement = screen.map(OverlayPlacement.init) ?? locate(game.pid) else { return }
        let panel = self.panel ?? OverlayPanel(frame: placement.rect)
        panel.setFrame(placement.rect, display: false)
        center.safeArea = placement.safeArea
        fullScreen = NSScreen.screens.contains { $0.frame == placement.rect }
        let view = OverlayRoot(center: center, controller: self)
        panel.contentView = NSHostingView(rootView: view)
        self.panel = panel
        shown = true
        center.setOpen(true)
        if activation.appHidden() { rehide = true }
        for window in pendingWindows + activation.hideWindows() where !hiddenWindows.contains(window) { hiddenWindows.append(window) }
        pendingWindows = []
        if presentationBefore == nil { presentationBefore = activation.presentation(OverlayWindows.presentation) }
        // On the game's Space before Cartouche activates, so macOS has no other Space to switch to
        activation.tellGame(game.pid, .willOpen)
        activation.show(panel)
        activation.settle { [weak self] in
            guard let self, self.shown else { return }
            self.activation.activateSelf()
        }
        installKeys()
        resources?.startViewing()
        startRefresh()
    }

    func close() {
        guard shown, let center else { return }
        shown = false
        center.setOpen(false)
        removeKeys()
        resources?.stopViewing()
        // After the game has the focus back, so the menu bar does not flash over it
        let panel = panel, hide = activation.hide
        activation.activateGame(center.game.pid)
        activation.tellGame(center.game.pid, .didClose)
        activation.guardFront(center.game.pid, 1.0)
        activation.whenGameFront(center.game.pid, 0.6) { [weak self] in
            guard let self, !self.shown else { return }
            if let panel { hide(panel) }
            if let before = self.presentationBefore {
                _ = self.activation.presentation(before)
                self.presentationBefore = nil
            }
            if self.rehide || self.fullScreen {
                if self.rehide { self.activation.hideApp() }
                self.pendingWindows += self.hiddenWindows
                self.watchActivation()
            } else {
                self.activation.restoreWindows(self.hiddenWindows)
            }
            self.hiddenWindows = []
            self.rehide = false
        }
        // Once the game has the focus back: restored earlier, it would minimize again
        let pid = center.game.pid, restore = activation.restoreGame
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, !self.shown else { return }
            restore(pid)
        }
    }

    var visible: Bool { shown }

    // The user came back to Cartouche: its windows return
    func appBecameActive() {
        guard !shown, !pendingWindows.isEmpty else { return }
        activation.bringBack(pendingWindows)
        pendingWindows = []
    }

    private func watchActivation() {
        guard activeObserver == nil else { return }
        activeObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.appBecameActive() }
        }
    }

    private func attach(_ game: OverlayGame) -> OverlayCenter {
        if let center, center.game.pid == game.pid { return center }
        var game = game
        // The game's own metrics block proves our library runs in it, even when another Cartouche launched it
        if !game.libraryLoaded, libraryPublishes(game.pid) { game.libraryLoaded = true }
        let center = OverlayCenter(game: game, soon: OverlayFeature.soon(defaults))
        center.actions = actions
        // One « Reprendre les apps après le jeu » for the window and the menu
        if let resume = resources?.resumesAfterGame {
            center.profile.saved.resumeApps = resume
            center.profile.current.resumeApps = resume
        }
        center.hotkey = registered?.label ?? HotkeyCombo.optionC.label
        center.hudHotkey = OverlayHotkey.hud(defaults).label
        center.threshold = Int(resources?.thresholds.otherCPU ?? 70)
        center.actions.setThreshold = { [weak self] v in self?.resources?.thresholds.otherCPU = Double(v) }
        center.actions.appAction = { [weak self] pid, action in self?.perform(action, on: pid) }
        center.actions.recordShortcut = { [weak self] in self?.recordShortcut() }
        center.live.captureAllowed = ExternalFrameCounter.allowed
        if let placement = locate(game.pid) { center.safeArea = placement.safeArea }
        if center.hudOutside {
            center.live.mac.battery = MacReaders.battery()
        } else {
            control = ControlBlockWriter(pid: game.pid)
        }
        center.hudChanged = { [weak self] c in
            var c = c
            c.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            self?.control?.write(c)
        }
        self.center = center
        control?.write(center.hudControl)
        if center.hudOutside { showNativeHUD(center) }
        return center
    }

    // Without our code in the game, its HUD is a panel of ours, which never takes the mouse
    private func showNativeHUD(_ center: OverlayCenter) {
        guard hudPanel == nil, let placement = locate(center.game.pid) else { return }
        let panel = OverlayPanel(frame: placement.rect, activating: false)
        panel.ignoresMouseEvents = true
        panel.level = NSWindow.Level(rawValue: OverlayPanel.level.rawValue - 1)
        panel.contentView = NSHostingView(rootView: OverlayHUDHost(center: center))
        activation.showHUD(panel)
        hudPanel = panel
        startRefresh()
    }

    // MARK: Live numbers

    private func startRefresh() {
        guard refresh == nil, let center else { return }
        if center.hudOutside { ensureCounter(pid: center.game.pid, allowed: center.live.captureAllowed) }
        refresh = Task { [weak self] in
            while !Task.isCancelled {
                self?.sample()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    // The game's own frames, counted from outside while capture is allowed
    @discardableResult
    func ensureCounter(pid: pid_t, allowed: Bool) -> Task<Void, Never>? {
        guard allowed, Date() >= counterRetryAt else { return nil }
        if counter?.dead == true {
            let dead = counter
            counter = nil
            Task { await dead?.stop() }
        }
        guard counter == nil else { return nil }
        let counter = makeCounter()
        self.counter = counter
        return Task {
            // No window yet or the stream failed: free it and try again later
            if await counter.start(pid: pid) || self.counter !== counter { return }
            self.counter = nil
            counterRetryAt = Date().addingTimeInterval(2)
        }
    }

    private func sample() {
        guard let center else { return }
        let pid = center.game.pid
        var live = center.live
        if center.hudOutside {
            if live.captureAllowed { ensureCounter(pid: pid, allowed: true) }
            live.metrics = counter?.metrics(now: ExternalFrameCounter.now())
            if let seconds = MacReaders.gpuSeconds(of: pid) {
                if let last = lastGPU { live.mac.gameGPUPercent = max(0, (seconds - last.seconds) / Date().timeIntervalSince(last.at) * 100) }
                lastGPU = (seconds, Date())
            }
        } else {
            live.metrics = MetricsBlockReader.read(pid: pid).flatMap(MetricsBlockReader.metrics)
        }
        live.mac.gpuPercent = MacReaders.gpuUtilization()
        live.mac.gpuWatts = power?.gpuWatts()
        live.mac.thermal = ProcessInfo.processInfo.thermalState.rawValue
        live.mac.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        live.mac.battery = MacReaders.battery()
        live.controller = GCController.controllers().first.map(ControllerInfo.init)
        if let sample = resources?.sample {
            let game = resources?.gamePIDs ?? []
            live.othersCPU = LoadCheck.otherCPU(sample, game: game.union([pid]))
            live.mac.cpuPercent = sample.cpuLoad
            live.mac.memoryUsed = sample.memory.used
            live.mac.memoryTotal = sample.memory.physical
            live.mac.memoryPressure = sample.memory.pressure
            live.mac.memoryBytes = sample.rows.filter { $0.pids.contains(where: { game.contains($0) || $0 == pid }) }.compactMap(\.memory).reduce(0, +)
            live.apps = sample.rows.compactMap { row in
                guard !row.pids.contains(where: { game.contains($0) || $0 == pid }), let resources else { return nil }
                let protection = resources.protection(of: row)
                guard protection == nil || protection == .system else { return nil }
                let cores = Double(max(1, sample.cores))
                return OverlayApp(pid: row.pid, name: row.name, cpu: (row.cpu ?? 0) / cores, gpu: row.gpu ?? 0,
                                  memoryGB: Double(row.memory ?? 0) / 1e9, paused: resources.isPaused(row),
                                  system: protection == .system)
            }
            .sorted { $0.cpu > $1.cpu }
        }
        if live != center.live { center.live = live }
        follow(center)
        control?.write(center.hudControl)
    }

    // A windowed game moves or resizes: the HUD keeps to its window's corner
    private func follow(_ center: OverlayCenter) {
        guard !shown, let placement = locate(center.game.pid) else { return }
        if center.safeArea != placement.safeArea { center.safeArea = placement.safeArea }
        if let hudPanel, hudPanel.frame != placement.rect { hudPanel.setFrame(placement.rect, display: true) }
    }

    private func perform(_ action: ResourceAction, on pid: pid_t) {
        guard let resources, let row = resources.sample?.rows.first(where: { $0.pid == pid }) else { return }
        resources.perform(action, on: row)
    }

    // MARK: Keyboard and controller

    private func installKeys() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .mouseMoved]) { [weak self] event in
            guard let self, let center = self.center, self.shown else { return event }
            if event.type != .keyDown {
                center.nav.input = .pointer
                return event
            }
            if center.recordingShortcut {
                switch Self.recordResult(for: event, other: OverlayHotkey.hud(self.defaults)) {
                case .cancel: center.recordingShortcut = false
                case .refuse(let why): center.toast(why)
                case .take(let combo):
                    center.recordingShortcut = false
                    OverlayHotkey.store(combo, self.defaults)
                    self.registered = OverlayHotkey.register(stored: combo, hud: OverlayHotkey.hud(self.defaults), with: self.hotkeys)
                    center.hotkey = self.registered?.label ?? center.hotkey
                case .swallow: break
                }
                return nil
            }
            // The notes field keeps its keys; esc leaves it
            if let responder = event.window?.firstResponder as? NSTextView, responder.isEditable {
                if event.keyCode == 53 { event.window?.makeFirstResponder(nil) ; return nil }
                if !(event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "s") { return event }
            }
            guard let key = Self.key(for: event) else { return event }
            if center.handle(key, by: .keyboard) == .close { self.close() }
            return nil
        }
        for pad in GCController.controllers() { watch(pad) }
    }

    private func removeKeys() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        for pad in GCController.controllers() { pad.extendedGamepad?.valueChangedHandler = nil }
    }

    enum RecordResult: Equatable { case cancel, refuse(String), take(HotkeyCombo), swallow }

    // While a shortcut is recorded: Esc gives up, a refused combo is told and recording goes on
    static func recordResult(for event: NSEvent, other: HotkeyCombo) -> RecordResult {
        if event.keyCode == 53 { return .cancel }
        guard let combo = HotkeyCombo(event: event) else { return .swallow }
        if let why = OverlayHotkey.refusal(of: combo, other: other) { return .refuse(why) }
        return .take(combo)
    }

    static func key(for event: NSEvent) -> OverlayKey? {
        if event.modifierFlags.contains(.command) { return event.charactersIgnoringModifiers == "s" ? .save : nil }
        switch Int(event.keyCode) {
        case 126: return .up
        case 125: return .down
        case 123: return .left
        case 124: return .right
        case 36, 76, 49: return .enter
        case 53, 51: return .escape
        case 48: return event.modifierFlags.contains(.shift) ? .backTab : .tab
        default: return nil
        }
    }

    // D-pad, A, B, LB/RB and Y while the menu is open; Home stays the system's (spike S3)
    private func watch(_ pad: GCController) {
        guard let gamepad = pad.extendedGamepad else { return }
        var held: Set<String> = []
        gamepad.valueChangedHandler = { [weak self] gamepad, element in
            let pressed: [(String, Bool, OverlayKey)] = [
                ("up", gamepad.dpad.up.isPressed, .up), ("down", gamepad.dpad.down.isPressed, .down),
                ("left", gamepad.dpad.left.isPressed, .left), ("right", gamepad.dpad.right.isPressed, .right),
                ("a", gamepad.buttonA.isPressed, .enter), ("b", gamepad.buttonB.isPressed, .escape),
                ("rb", gamepad.rightShoulder.isPressed, .tab), ("lb", gamepad.leftShoulder.isPressed, .backTab),
                ("y", gamepad.buttonY.isPressed, .save),
            ]
            for (name, down, key) in pressed {
                if down && !held.contains(name) {
                    held.insert(name)
                    MainActor.assumeIsolated {
                        guard let self, let center = self.center, self.shown else { return }
                        if center.handle(key, by: .controller) == .close { self.close() }
                    }
                } else if !down {
                    held.remove(name)
                }
            }
        }
    }

    private func recordShortcut() {}

    // MARK: Games

    // A Wine game: its process runs a Windows .exe; its folder tells whether it ships an anti-cheat
    static func gameFromProcess(_ app: NSRunningApplication) -> OverlayGame? {
        guard app.processIdentifier != getpid() else { return nil }
        let info = GameProcesses.info(of: app.processIdentifier)
        let exe = info?.arguments.first(where: { $0.lowercased().hasSuffix(".exe") })
        let path = info?.path ?? app.executableURL?.path ?? ""
        guard exe != nil || path.lowercased().contains("wine") else { return nil }
        let stem = exe.map { URL(filePath: $0).deletingPathExtension().lastPathComponent }
        let name = OverlayGameMatch.displayName(app.localizedName.flatMap { $0.lowercased().contains("wine") ? nil : $0 } ?? stem ?? "Game")
        var antiCheat: String?
        if let exe, FileManager.default.fileExists(atPath: exe) {
            let folder = URL(filePath: exe).deletingLastPathComponent()
            let found = GameAntiCheat.marks.first { FileManager.default.fileExists(atPath: folder.appending(path: $0).path(percentEncoded: false)) }
            if let found { antiCheat = GameAntiCheat.name(ofMark: found) }
        }
        return OverlayGame(id: (stem ?? name).lowercased(), name: name, pid: app.processIdentifier, antiCheat: antiCheat)
    }
}

struct OverlayRoot: View {
    @Bindable var center: OverlayCenter
    let controller: OverlayController
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        OverlayView(center: center, shown: center.isOpen, close: { controller.close() })
            .environment(\.overlayLook, OverlayLook(reduceTransparency: reduceTransparency, contrast: contrast == .increased,
                                                    reduceMotion: reduceMotion, liquid: GlassMode.system == .liquid))
    }
}

struct OverlayHUDHost: View {
    @Bindable var center: OverlayCenter
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HUDOverlayCorner(center: center)
            .environment(\.colorScheme, .dark)
            .environment(\.overlayLook, OverlayLook(reduceTransparency: reduceTransparency, contrast: contrast == .increased,
                                                    reduceMotion: reduceMotion, liquid: GlassMode.system == .liquid))
    }
}
