import AppKit
import Darwin
import Foundation
import Observation

@MainActor
protocol ProcessActions {
    func quit(_ row: ResourceUsage)
    func forceQuit(_ row: ResourceUsage)
}

// An app is asked to quit through AppKit, so it can save; a lone process gets SIGTERM.
struct LiveProcessActions: ProcessActions {
    func quit(_ row: ResourceUsage) {
        if let app = NSRunningApplication(processIdentifier: row.pid), app.terminate() { return }
        _ = kill(row.pid, SIGTERM)
    }

    func forceQuit(_ row: ResourceUsage) {
        if let app = NSRunningApplication(processIdentifier: row.pid), app.forceTerminate() { return }
        _ = kill(row.pid, SIGKILL)
    }
}

enum ResourceAction: Equatable {
    case quit, forceQuit, pause, resume
}

@MainActor
@Observable
final class ResourceMonitor {

    static let protectedKey = "resources.protected"
    static let resumeKey = "resources.resumeAfterGame"
    static let viewInterval: Duration = .seconds(1)
    static let gameInterval: Duration = .seconds(5)
    // How long a launched game may take to show before the watch gives up
    static let gameStartWait: Duration = .seconds(120)

    private(set) var sample: ResourceSample?
    private(set) var protection: [pid_t: Protection] = [:]
    private(set) var pausedPIDs: Set<pid_t> = []
    // The warning the library shows until dismissed
    var alert: LoadVerdict?
    private(set) var watchingGame = false

    var thresholds: LoadThresholds {
        didSet { if thresholds != oldValue { thresholds.save(defaults) } }
    }
    var userProtected: [String] {
        didSet {
            guard userProtected != oldValue else { return }
            defaults.set(userProtected, forKey: Self.protectedKey)
            reclassify()
        }
    }

    @ObservationIgnored let paused: PausedProcesses
    @ObservationIgnored var source: any ResourceSource
    @ObservationIgnored var actions: any ProcessActions
    @ObservationIgnored var apps: @MainActor () -> [pid_t: RunningAppInfo] = ResourceMonitor.runningApps
    @ObservationIgnored var isGameRunning: @MainActor () async -> Bool = { false }
    @ObservationIgnored var notify: @MainActor (LoadVerdict) -> Void = { _ in }
    @ObservationIgnored var showWindow: @MainActor () -> Void = {}
    // The in-game menu's shortcut lives from a game's launch to its end
    @ObservationIgnored var gameStarted: @MainActor () -> Void = {}
    // Where launch folders wait for the app, set by the app; nil records no context
    @ObservationIgnored var contextFolder: URL?
    @ObservationIgnored var gameEnded: @MainActor () -> Void = {}
    // « Reprendre les apps après le jeu », in the window and the in-game menu
    var resumesAfterGame: Bool {
        didSet { if resumesAfterGame != oldValue { defaults.set(resumesAfterGame, forKey: Self.resumeKey) } }
    }
    @ObservationIgnored var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var sampler = ResourceSampler()
    @ObservationIgnored private var lastApps: [pid_t: RunningAppInfo] = [:]
    @ObservationIgnored private var viewers = 0
    @ObservationIgnored private var viewing: Task<Void, Never>?
    @ObservationIgnored private var gameWatch: Task<Void, Never>?

    init(source: any ResourceSource = LiveResourceSource(), paused: PausedProcesses? = nil,
         actions: any ProcessActions = LiveProcessActions(), defaults: UserDefaults = .standard) {
        self.source = source
        self.paused = paused ?? PausedProcesses()
        self.actions = actions
        self.defaults = defaults
        thresholds = LoadThresholds.load(defaults)
        // A stored list still equal to the beta's shipped one means the user never chose: it resets
        let stored = defaults.stringArray(forKey: Self.protectedKey)
        if let stored, stored == ProtectedProcesses.betaUserList {
            userProtected = []
            defaults.set([String](), forKey: Self.protectedKey)
        } else {
            userProtected = stored ?? ProtectedProcesses.defaultUserList
        }
        resumesAfterGame = defaults.object(forKey: Self.resumeKey) as? Bool ?? true
        pausedPIDs = self.paused.pids
    }

    static func runningApps() -> [pid_t: RunningAppInfo] {
        var apps: [pid_t: RunningAppInfo] = [:]
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy != .prohibited {
            guard let bundle = app.bundleURL else { continue }
            apps[app.processIdentifier] = RunningAppInfo(
                name: app.localizedName ?? bundle.deletingPathExtension().lastPathComponent,
                bundleID: app.bundleIdentifier, bundlePath: bundle.path(percentEncoded: false))
        }
        return apps
    }

    var rules: ProtectedProcesses {
        var rules = ProtectedProcesses()
        rules.userList = userProtected
        return rules
    }

    // The Steam launcher's processes count as the game only while a game actually runs
    var gamePIDs: Set<pid_t> {
        var game = Set(protection.filter { $0.value == .game }.keys)
        if !game.isEmpty { game.formUnion(protection.filter { $0.value == .launcher }.keys) }
        return game
    }

    func protection(of row: ResourceUsage) -> Protection? {
        ProtectedProcesses.protection(of: row, in: protection)
    }

    func isPaused(_ row: ResourceUsage) -> Bool { row.pids.contains(where: pausedPIDs.contains) }

    // MARK: Reading

    @discardableResult
    func refresh() async -> ResourceSample? {
        let source = source
        let reading = await Task.detached(priority: .utility) { source.read() }.value
        lastApps = apps()
        guard let next = sampler.sample(reading, apps: lastApps) else { return nil }
        sample = next
        reclassify()
        return next
    }

    private func reclassify() {
        guard let sample else { return }
        protection = rules.classify(sample.processes, apps: lastApps, unreadable: Set(sample.gpuByPID.keys))
    }

    // The view reads every second while it is open; nothing runs once it closes.
    func startViewing() {
        viewers += 1
        guard viewing == nil else { return }
        viewing = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                try? await self.sleep(self.sample == nil ? .milliseconds(500) : Self.viewInterval)
            }
        }
    }

    func stopViewing() {
        viewers = max(0, viewers - 1)
        guard viewers == 0 else { return }
        viewing?.cancel()
        viewing = nil
    }

    // MARK: Actions

    func perform(_ action: ResourceAction, on row: ResourceUsage) {
        guard protection(of: row) == nil else {
            AppLog.note("refused \(action) on protected \(row.name)")
            return
        }
        switch action {
        case .quit:
            if isPaused(row) { paused.resume(Set(row.pids)) }
            actions.quit(row)
        case .forceQuit:
            actions.forceQuit(row)
            paused.forgetGone(Set(row.pids))
        case .pause:
            guard let sample else { return }
            let targets = row.pids.compactMap { pid in
                sample.processes[pid].map { PausedProcess(pid: pid, started: $0.started, name: $0.name) }
            }
            paused.pause(targets)
        case .resume:
            paused.resume(Set(row.pids))
        }
        pausedPIDs = paused.pids
    }

    func resumeAll(why: String) {
        guard !paused.entries.isEmpty else { return }
        AppLog.note("resuming paused processes: \(why)")
        paused.resumeAll()
        pausedPIDs = paused.pids
    }

    // At launch: anything a crashed or killed Cartouche left stopped goes again.
    func start() {
        if !paused.entries.isEmpty { AppLog.note("resuming \(paused.entries.count) processes left paused") }
        paused.resumeLeftovers()
        pausedPIDs = paused.pids
    }

    // MARK: Game watch

    // A check right at launch, then a light sample every few seconds while the game runs.
    // The warning comes once per game, and only after two samples in a row agree.
    func gameLaunched() {
        guard gameWatch == nil else { return }
        watchingGame = true
        gameStarted()
        gameWatch = Task { [weak self] in
            await self?.watchGame()
            self?.gameWatch = nil
            self?.watchingGame = false
            self?.gameEnded()
        }
    }

    func watchGame() async {
        var warned = false
        if thresholds.enabled {
            await refresh()
            try? await sleep(.seconds(1))
            if let verdict = await check() {
                warn(verdict)
                warned = true
            }
        }
        let started = ContinuousClock.now
        var seen = false
        var strikes = 0
        var context = SessionContextRecorder(display: SessionContextRecorder.display())
        var ticks = 0
        let launched = Date().addingTimeInterval(-120)
        while !Task.isCancelled {
            try? await sleep(Self.gameInterval)
            let running = await isGameRunning()
            if running { seen = true }
            if !running {
                if seen { break }
                if ContinuousClock.now - started > Self.gameStartWait { return }
                continue
            }
            // Every 30 s, for the session's context: the A/B comparison needs to know what else ran
            if ticks % 6 == 0, let sample = await refresh(), let incoming = contextFolder {
                context.add(othersCPU: LoadCheck.otherCPU(sample, game: gamePIDs), thermal: ProcessInfo.processInfo.thermalState.rawValue)
                SessionContextRecorder.write(context.lines, incoming: incoming, since: launched)
            }
            ticks += 1
            guard thresholds.enabled, !warned else { continue }
            if let verdict = await check() {
                strikes += 1
                if strikes >= 2 {
                    warn(verdict)
                    warned = true
                }
            } else {
                strikes = 0
            }
        }
        if resumesAfterGame { resumeAll(why: "the game ended") }
    }

    func check() async -> LoadVerdict? {
        guard let sample = await refresh() else { return nil }
        let fixed = Set(protection.filter { $0.value != .user }.keys)
        return LoadCheck.verdict(sample, game: gamePIDs, protected: fixed, thresholds: thresholds)
    }

    private func warn(_ verdict: LoadVerdict) {
        AppLog.note("Mac under load at game time: \(verdict.reasons.map(\.text).joined(separator: " "))")
        alert = verdict
        notify(verdict)
    }

    func stopWatchingGame() {
        gameWatch?.cancel()
        gameWatch = nil
        watchingGame = false
    }
}
