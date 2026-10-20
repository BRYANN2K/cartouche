import Foundation

public struct PlayRequest: Sendable, Equatable {
    public var core: URL
    public var content: URL
    public var slot: Int?
    public var resume = false
    public var look: ConsoleLook = .original
    public var lowerInputLag = false
    public var hardcore = false
    public var disc = 0
    public var netplay: NetplayRole?
    public var netplayNickname: String?
    public var achievements: AchievementsLogin?
    public var translation: TranslationSetup?

    public init(core: URL, content: URL) {
        self.core = core
        self.content = content
    }
}

public struct PlayReport: Sendable, Equatable {
    public var stop: StopReport
    public var played: Duration

    public init(stop: StopReport, played: Duration) {
        self.stop = stop
        self.played = played
    }
}

public actor ConsolePlayer {

    public let launcher: ConsoleLauncher
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
        launch.config.netplayNickname = request.netplayNickname
        launch.config.achievements = request.achievements
        launch.config.translation = request.translation
        // AI_SERVICE is a hotkey, not an MCP tool: Translate Now sends it over UDP
        if request.translation != nil { launch.config.networkCommands = true }
        launch.netplay = request.netplay
        if case .host(_, let announce) = request.netplay { launch.config.netplayAnnounce = announce }
        launch.config.extra = launch.config.extra.merging(extra) { $1 }
        let session = RetroArchSession(launch: launch)

        do {
            if launch.mcp {
                try await session.start()
                try await session.load(core: request.core, content: request.content)
                // RetroArch re-reads its configuration as it loads the core and has signed in by now: the token does not stay in cartouche.cfg.
                if request.achievements != nil { try? launch.config.withoutSecrets.write() }
                self.session = session
                self.request = request
                started = .now
                if request.disc > 0 { try await insert(disc: request.disc, from: 0) }
                if let slot = request.slot { try await session.loadState(slot: slot) }
                if request.look != .original { try await apply(request.look) }
            } else {
                try await session.start(core: request.core, content: request.content)
                self.session = session
                self.request = request
                started = .now
                // The -L launch re-reads nothing: the token leaves the config now
                if request.achievements != nil { Self.scrubSecrets(in: paths) }
            }
        } catch {
            _ = await session.stop()
            // A failed start or load still wrote the token into cartouche.cfg
            Self.scrubSecrets(in: paths)
            self.session = nil
            self.request = nil
            started = nil
            throw error
        }
    }

    // SET_SHADER answers once the shader is on screen.
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

    @discardableResult
    public func quit() async -> PlayReport {
        guard let session else { return PlayReport(stop: StopReport(way: .notRunning, duration: .zero), played: .zero) }
        let stop = await session.stop()
        let played = started.map { .now - $0 } ?? .zero
        if request?.achievements != nil { Self.scrubSecrets(in: launcher.paths) }
        self.session = nil
        request = nil
        started = nil
        return PlayReport(stop: stop, played: played)
    }

    public func ended() async -> PlayReport? {
        guard let session, await !session.isRunning else { return nil }
        return await quit()
    }

    // What RetroArch says of hardcore: on only once achievements are loaded
    public func hardcoreActive() async throws -> Bool {
        guard let session else { throw RetroArchSessionError.notRunning }
        return try await session.option("cheevos_hardcore") == "on"
    }

    public func log(since: Int) async throws -> (lines: [String], next: Int) {
        guard let session else { throw RetroArchSessionError.notRunning }
        return try await session.log(since: since)
    }

    public func translateNow() async throws {
        guard let session, request?.translation != nil else { throw RetroArchSessionError.notRunning }
        try await session.command("AI_SERVICE")
    }

    // RetroArch seals the token in retroarch-keychain.cfg beside a key file; Cartouche keeps it in the macOS keychain only, so both copies go once RetroArch is gone.
    public static func scrubSecrets(in paths: RetroArchPaths) {
        let files = FileManager.default
        let folder = paths.baseConfig.deletingLastPathComponent()
        try? files.removeItem(at: folder.appending(path: "retroarch-keychain.cfg"))
        for file in [paths.baseConfig, paths.appendConfig] {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let kept = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
                let key = line.split(separator: "=", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces) ?? ""
                return ["cheevos_token", "cheevos_password"].contains(key) ? "\(key) = \"\"" : String(line)
            }.joined(separator: "\n")
            if kept != text { try? Data(kept.utf8).write(to: file, options: .atomic) }
        }
    }
}
