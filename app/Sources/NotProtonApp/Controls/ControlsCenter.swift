import AppKit
import Foundation
import GameController
import Observation

// The Controls sheet's options for one game. Each permission is asked from
// here, never in onboarding.
@MainActor
final class ControlsSession {
    let game: Game
    // Remap keys for this game: Input Monitoring, applied after a relaunch
    let remap: GatedOption
    // Play with a controller: Accessibility
    let play: GatedOption
    // Reopened after a relaunch for Input Monitoring
    var opensOnKeyboard = false

    // One flow each, so each row shows its own explanation
    init(game: Game, controls: GameControls, remapFlow: PermissionFlow, playFlow: PermissionFlow) {
        self.game = game
        remap = GatedOption(.inputMonitoring, flow: remapFlow, isOn: controls.remapKeys)
        play = GatedOption(.accessibility, flow: playFlow, isOn: controls.playWithController)
    }
}

@MainActor
@Observable
final class ControlsCenter {

    let monitor: ControllerMonitor
    let couch: CouchNavigator
    // The game whose Controls sheet is open
    private(set) var presented: Game?
    private(set) var session: ControlsSession?
    private(set) var controls: [String: GameControls] = [:]
    var problem: String?

    @ObservationIgnored let store: ControlsStore
    @ObservationIgnored var files: ControlsFiles
    // Input Monitoring's flow, which the relaunch service watches, and Accessibility's
    @ObservationIgnored let flow: PermissionFlow
    @ObservationIgnored let playFlow: PermissionFlow
    @ObservationIgnored weak var relaunch: RelaunchService?
    @ObservationIgnored weak var library: LibraryModel?
    @ObservationIgnored let reader: any PadReader
    @ObservationIgnored let focus: any GameFocus
    @ObservationIgnored let keyboardPlay: KeyboardPlayBridge
    @ObservationIgnored let remapper: KeyRemapper
    // Whether Cartouche is the frontmost app; couch mode acts only then
    @ObservationIgnored var isActive: @MainActor () -> Bool = { NSApp.isActive }
    // Game controller events reach a background app only when asked for
    @ObservationIgnored var backgroundEvents: @MainActor (Bool) -> Void = { GCController.shouldMonitorBackgroundEvents = $0 }
    @ObservationIgnored private var monitoringBackground = false
    @ObservationIgnored var open: @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var frontObserver: (any NSObjectProtocol)?
    // The option-using game that is in front, found on each tick
    @ObservationIgnored private(set) var frontmostGame: Game?

    init(
        permissions: PermissionCenter, files: ControlsFiles, store: ControlsStore = ControlsStore(),
        source: any ControllerSource = GameControllerSource(), reader: any PadReader = GameControllerPadReader(),
        poster: any InputPoster = LiveInputPoster(), focus: any GameFocus = LiveGameFocus(),
        tap: any KeyTapping = LiveKeyTap(), defaults: UserDefaults = .standard
    ) {
        monitor = ControllerMonitor(source: source)
        couch = CouchNavigator(defaults: defaults)
        self.store = store
        self.files = files
        flow = PermissionFlow(center: permissions)
        playFlow = PermissionFlow(center: permissions)
        self.reader = reader
        self.focus = focus
        keyboardPlay = KeyboardPlayBridge(reader: reader, poster: poster, focus: focus)
        remapper = KeyRemapper(tap: tap)
    }

    var permissions: PermissionCenter { flow.center }

    func load() async {
        controls = await store.all()
    }

    // The library the games come from, and the relaunch service that reopens Controls
    func connect(relaunch: RelaunchService, library: LibraryModel) {
        self.relaunch = relaunch
        self.library = library
        couch.library = library
        relaunch.center = permissions
        // The screen to reopen if macOS's Quit & Reopen comes after the Input Monitoring prompt
        relaunch.watch(flow) { [weak self] in self?.route }
    }

    // The app's own start: controllers, the saved choices, and the poll
    func start(relaunch: RelaunchService, library: LibraryModel) async {
        // The window's task runs again when the window comes back
        guard loop == nil else { return }
        connect(relaunch: relaunch, library: library)
        monitor.start()
        await load()
        couch.start()
        // Frontmost changes start and stop the taps; the fast poll only runs
        // while a game that needs it is the one in front
        frontObserver = NotificationCenter.default.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick(now: ProcessInfo.processInfo.systemUptime) }
        }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let fast = self.wantsFastPoll
                if fast || self.needsPolling { self.tick(now: ProcessInfo.processInfo.systemUptime) }
                try? await Task.sleep(for: fast ? .milliseconds(16) : .seconds(1))
            }
        }
    }

    func controls(for game: Game) -> GameControls { controls[game.id] ?? GameControls() }

    // MARK: The sheet

    func present(_ game: Game) {
        session = ControlsSession(game: game, controls: controls(for: game), remapFlow: flow, playFlow: playFlow)
        session?.remap.onWaitingForRelaunch = { [weak self] in self?.relaunch?.markWaiting($0) }
        presented = game
    }

    func dismiss() {
        presented = nil
        session = nil
    }

    var route: ScreenRoute? { presented.map { ScreenRoute.controls(game: $0.id, finishing: .inputMonitoring) } }

    // After a relaunch the relaunch service asked for: the same game's Controls,
    // with the option the permission was for turned on without asking again
    func reopen(_ route: ScreenRoute) async {
        guard route.screen == "controls", let id = route.detail, let game = library?.game(id) else { return }
        library?.select(id)
        await permissions.refresh()
        present(game)
        if route.finishing == .inputMonitoring, let session {
            session.opensOnKeyboard = true
            session.remap.finishAfterRelaunch()
            if session.remap.isOn { await update(game) { $0.remapKeys = true } }
        }
    }

    // Saves the choice and writes what the next launch reads
    func update(_ game: Game, _ change: (inout GameControls) -> Void) async {
        var value = controls(for: game)
        change(&value)
        guard value != controls(for: game) else { return }
        controls[game.id] = value
        do {
            try await store.set(value, for: game.id)
            try files.apply(value, to: game)
            problem = nil
        } catch {
            problem = String(localized: "Cartouche couldn’t save the controls: \(error.localizedDescription)")
        }
        tick(now: ProcessInfo.processInfo.systemUptime)
    }

    // Steam Input's settings for the game live in Steam
    func openInSteam(_ game: Game) {
        guard let appID = game.steamAppID else { return }
        open(URL(string: "steam://nav/games/details/\(appID)")!)
    }

    // MARK: The poll

    // Games whose option is on and whose permission macOS gave
    var keyboardPlayGames: [Game] {
        guard permissions.state(.accessibility) == .allowed else { return [] }
        return games { $0.playWithController }
    }

    var keyRemapGames: [Game] {
        guard permissions.state(.inputMonitoring) == .allowed else { return [] }
        return games { $0.remapKeys && !$0.keyRemaps.isEmpty }
    }

    private func games(_ wanted: (GameControls) -> Bool) -> [Game] {
        controls.filter { wanted($0.value) }.keys.sorted().compactMap { library?.game($0) }
    }

    var needsPolling: Bool { couch.isOn || !keyboardPlayGames.isEmpty || !keyRemapGames.isEmpty }

    // 16 ms only while a game that needs it, or couch mode's own window, is in
    // front; everything else ticks once a second and on frontmost changes
    private var wantsFastPoll: Bool {
        if couch.isOn && isActive() { return true }
        guard let frontmostGame else { return false }
        return keyboardPlayGames.contains { $0.id == frontmostGame.id }
    }

    // Posted keys and mouse buttons go up before the process goes away
    func endForTermination() {
        keyboardPlay.reset()
    }

    func tick(now: Double) {
        let state = reader.read()
        couch.tick(isActive() ? state : nil, at: now)

        let playing = keyboardPlayGames
        let remapping = keyRemapGames
        let frontmost = (playing + remapping).first(where: focus.isFrontmost)
        frontmostGame = frontmost

        let wantBackground = !playing.isEmpty
        if wantBackground != monitoringBackground {
            monitoringBackground = wantBackground
            backgroundEvents(wantBackground)
        }

        if let game = playing.first(where: { $0.id == frontmost?.id }) {
            keyboardPlay.tick(game)
        } else {
            keyboardPlay.reset()
        }

        if let game = remapping.first(where: { $0.id == frontmost?.id }) {
            if !remapper.tick(game, remaps: controls(for: game).keyRemaps), problem == nil {
                problem = String(localized: "macOS did not let Cartouche read the keyboard. Check Input Monitoring in System Settings.")
            }
        } else {
            remapper.stop()
        }
    }
}
