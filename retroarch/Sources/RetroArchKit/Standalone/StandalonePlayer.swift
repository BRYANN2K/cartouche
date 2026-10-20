import AppKit
import Foundation

public enum StandaloneError: Error, Equatable, LocalizedError {
    case exitedEarly(emulator: String, status: Int32)
    // A single-instance app hands a second launch to the one already open and exits 0: the game runs, but the session is over.
    case handedOff(emulator: String)

    public var errorDescription: String? {
        switch self {
        case .exitedEarly(let emulator, let status):
            String(localized: "\(emulator) quit at once (exit code \(status)).", bundle: .module)
        case .handedOff(let emulator):
            String(localized: "\(emulator) is already running. Quit the open \(emulator) first.", bundle: .module)
        }
    }
}

public actor StandalonePlayer {

    public let emulator: InstalledEmulator
    public var environment: [String: String]?
    public var log: URL?
    public var quitLimits: (polite: Duration, term: Duration) = (.seconds(8), .seconds(4))
    // An emulator gone within this time did not start
    public var startCheck: Duration = .milliseconds(500)

    private var child: ChildProcess?
    private var started: ContinuousClock.Instant?

    public init(emulator: InstalledEmulator, environment: [String: String]? = nil, log: URL? = nil) {
        self.emulator = emulator
        self.environment = environment
        self.log = log
    }

    public func setEnvironment(_ environment: [String: String]?) { self.environment = environment }

    public func setQuitLimits(polite: Duration, term: Duration) { quitLimits = (polite, term) }

    public var isPlaying: Bool { child.map { $0.exitStatus == nil } ?? false }

    public var processIdentifier: Int32? { child?.identifier }

    public func play(_ request: PlayRequest) async throws {
        if child != nil { _ = await quit() }
        if let log { try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true) }
        let child = try ChildProcess(
            executable: emulator.executable, arguments: emulator.emulator.arguments(for: request.content),
            environment: environment, stderr: log, pipes: false, onLine: { _ in })
        // Any exit inside startCheck means it did not start - or handed off to an already open copy, where the session would end at once.
        if await child.waitForExit(within: startCheck), let status = child.exitStatus {
            throw status == 0
                ? StandaloneError.handedOff(emulator: emulator.emulator.name)
                : StandaloneError.exitedEarly(emulator: emulator.emulator.name, status: status)
        }
        self.child = child
        started = .now
        Self.bringForward(child.identifier)
    }

    public func waitUntilExit() async {
        if let child { _ = await child.exited() }
    }

    // Quits as the emulator's own Quit does so it can save; then SIGTERM, and SIGKILL only when ignored.
    @discardableResult
    public func quit() async -> PlayReport {
        guard let child else { return PlayReport(stop: StopReport(way: .notRunning, duration: .zero), played: .zero) }
        let begin = ContinuousClock.now
        var way = StopReport.Way.quit
        if child.exitStatus == nil {
            let asked = NSRunningApplication(processIdentifier: child.identifier)?.terminate() ?? false
            let quitPolitely = asked ? await child.waitForExit(within: quitLimits.polite) : false
            if !quitPolitely {
                way = .terminated
                child.signal(SIGTERM)
                if !(await child.waitForExit(within: quitLimits.term)) {
                    way = .killed
                    child.signal(SIGKILL)
                    _ = await child.waitForExit(within: .seconds(2))
                }
            }
        }
        return finish(StopReport(way: way, duration: .now - begin))
    }

    public func ended() async -> PlayReport? {
        guard let child, child.exitStatus != nil else { return nil }
        return finish(StopReport(way: .quit, duration: .zero))
    }

    // Cartouche is quitting: the emulator is the user's own app and keeps running
    public func release() -> PlayReport {
        finish(StopReport(way: .notRunning, duration: .zero))
    }

    private func finish(_ stop: StopReport) -> PlayReport {
        let played = started.map { .now - $0 } ?? .zero
        child = nil
        started = nil
        return PlayReport(stop: stop, played: played)
    }

    public func setLook(_ look: ConsoleLook) async throws {}
    public func setLowerInputLag(_ on: Bool) async throws {}
    public func setHardcore(_ on: Bool) async throws {}
    public func setDisc(_ disc: Int) async throws {}

    // An app started from its executable stays behind Cartouche until asked forward; a command-line stand-in has no app to bring.
    private static func bringForward(_ pid: Int32) {
        Task.detached {
            for _ in 0..<30 {
                if let app = NSRunningApplication(processIdentifier: pid) {
                    if app.activationPolicy == .regular {
                        app.activate()
                        return
                    }
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }
}
