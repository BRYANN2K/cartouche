import Foundation

// One game to start, with the choices of its panel
public struct PlayRequest: Sendable, Equatable {
    public var core: URL
    public var content: URL
    // Load this slot once the game runs
    public var slot: Int?
    // Load the auto state the last Quit wrote
    public var resume = false
    public var look: ConsoleLook = .original
    public var lowerInputLag = false
    public var hardcore = false
    // The disc of a multi-disc set to start from, from 0
    public var disc = 0

    public init(core: URL, content: URL) {
        self.core = core
        self.content = content
    }
}

public struct PlayReport: Sendable, Equatable {
    public var stop: StopReport
    // From the game starting to RetroArch gone
    public var played: Duration

    public init(stop: StopReport, played: Duration) {
        self.stop = stop
        self.played = played
    }
}

// Plays one console game at a time on the chosen RetroArch: starts it with the
// panel's choices, changes the look and disc while it runs, and quits it so
// that RetroArch writes its auto state.
public actor ConsolePlayer {

    public let launcher: ConsoleLauncher
    // For tests and diagnostics: drivers, logging
    public var extra: [String: String] = [:]
    public private(set) var session: RetroArchSession?
    public private(set) var request: PlayRequest?
    private var started: ContinuousClock.Instant?
    private var language: Looks.Language = .slang

    public init(launcher: ConsoleLauncher) {
        self.launcher = launcher
    }

    public func setExtra(_ extra: [String: String]) { self.extra = extra }

    public var isPlaying: Bool {
        get async {
            guard let session else { return false }
            return await session.isRunning
        }
    }

    public func play(_ request: PlayRequest) async throws {
        if session != nil { _ = await quit() }
        let paths = launcher.paths
        try Looks.install(in: paths)
        var launch = launcher.launch()
        launch.config.autoLoadState = request.resume && request.slot == nil
        launch.config.runAhead = request.lowerInputLag
        launch.config.hardcore = request.hardcore
        launch.config.extra = launch.config.extra.merging(extra) { $1 }
        let session = RetroArchSession(launch: launch)

        guard launch.mcp else {
            try await session.start(core: request.core, content: request.content)
            self.session = session
            self.request = request
            started = .now
            return
        }
        try await session.start()
        do {
            try await session.load(core: request.core, content: request.content)
            self.session = session
            self.request = request
            started = .now
            if request.disc > 0 { try await insert(disc: request.disc, from: 0) }
            if let slot = request.slot { try await session.loadState(slot: slot) }
            if request.look != .original { try await apply(request.look) }
        } catch {
            _ = await session.stop()
            self.session = nil
            self.request = nil
            started = nil
            throw error
        }
    }

    // Applied while the game runs; SET_SHADER answers once it is on screen
    public func setLook(_ look: ConsoleLook) async throws {
        request?.look = look
        guard session != nil else { return }
        try await apply(look)
    }

    private func apply(_ look: ConsoleLook) async throws {
        guard let session else { return }
        guard look != .original else {
            try await session.setShader(nil)
            return
        }
        let paths = launcher.paths
        do {
            try await session.setShader(Looks.preset(look, language, in: paths))
        } catch RetroArchSessionError.toolFailed(_, let reason) where reason.contains("cannot run this kind of shader") {
            // The OpenGL driver runs GLSL, the others slang
            language = language == .slang ? .glsl : .slang
            try await session.setShader(Looks.preset(look, language, in: paths))
        }
    }

    public func setLowerInputLag(_ on: Bool) async throws {
        request?.lowerInputLag = on
        try await session?.setOption("runahead", on: on)
    }

    public func setHardcore(_ on: Bool) async throws {
        request?.hardcore = on
        try await session?.setOption("cheevos_hardcore", on: on)
    }

    // Opens the tray, steps to the disc, closes the tray
    public func setDisc(_ disc: Int) async throws {
        guard let current = request?.disc, current != disc else { return }
        try await insert(disc: disc, from: current)
        request?.disc = disc
    }

    private func insert(disc: Int, from current: Int) async throws {
        guard let session else { return }
        try await session.disk(.eject)
        for _ in 0..<abs(disc - current) { try await session.disk(disc > current ? .next : .prev) }
        try await session.disk(.eject)
    }

    // Quits as RetroArch's own Quit does, so the auto state is written
    @discardableResult
    public func quit() async -> PlayReport {
        guard let session else { return PlayReport(stop: StopReport(way: .notRunning, duration: .zero), played: .zero) }
        let stop = await session.stop()
        let played = started.map { .now - $0 } ?? .zero
        self.session = nil
        request = nil
        started = nil
        return PlayReport(stop: stop, played: played)
    }

    // RetroArch quit by itself: what was played, once
    public func ended() async -> PlayReport? {
        guard let session, await !session.isRunning else { return nil }
        return await quit()
    }
}
