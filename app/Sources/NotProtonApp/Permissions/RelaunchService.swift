// Relaunching is Cartouche's job: it waits for running games, saves the screen, starts a new copy once this one quit, which reopens there.

import AppKit
import Foundation
import Observation
import SwiftUI

protocol GameActivity: Sendable {
    func isGameRunning() async -> Bool
}

struct RunnerGameActivity: GameActivity {
    func isGameRunning() async -> Bool {
        await Task.detached(priority: .utility) {
            RunnerRegistry.clonedBuilds().contains {
                RunnerInstaller.isRunning(from: SupportPaths.runnerRoot(forBuild: $0))
            }
        }.value
    }
}

struct CompositeGameActivity: GameActivity {
    let activities: [any GameActivity]

    init(_ activities: [any GameActivity]) { self.activities = activities }

    func isGameRunning() async -> Bool {
        for activity in activities where await activity.isGameRunning() { return true }
        return false
    }
}

@MainActor
struct ConsoleGameActivity: GameActivity {
    let center: ConsoleCenter
    func isGameRunning() async -> Bool { center.playing != nil }
}

@MainActor
protocol Relauncher {
    func relaunch() -> Bool
}

struct LiveRelauncher: Relauncher {
    var bundle: URL = Bundle.main.bundleURL

    func relaunch() -> Bool {
        let pid = ProcessInfo.processInfo.processIdentifier
        do {
            _ = try Self.reopen(after: pid, run: ["/usr/bin/open", "-n", bundle.path(percentEncoded: false)])
            AppLog.note("relaunching \(bundle.path(percentEncoded: false))")
            NSApp.terminate(nil)
            return true
        } catch {
            AppLog.note("relaunch failed: \(error.localizedDescription)")
            return false
        }
    }

    // A shell outlives the app, polls until `pid` is gone, then runs the command. If the app is still there after 30 seconds the quit was cancelled, so it gives up.
    static func reopen(after pid: Int32, run command: [String]) throws -> Process {
        let script = """
            n=0
            while /bin/kill -0 "$0" 2>/dev/null; do
              [ $n -ge 300 ] && exit 0
              /bin/sleep 0.1
              n=$((n + 1))
            done
            exec "$@"
            """
        let shell = Process()
        shell.executableURL = URL(filePath: "/bin/sh")
        shell.arguments = ["-c", script, String(pid)] + command
        try shell.run()
        return shell
    }
}

@MainActor
@Observable
final class RelaunchService {

    enum Phase: Equatable {
        case idle
        case waitingForGame
        case relaunching
    }

    struct Banner: Equatable {
        let title: String
        let message: String?
        let button: String
    }

    private(set) var phase: Phase = .idle
    // Asked, and the user picked Later in macOS's alert. A refusal drops out.
    private var asked: Set<Permission> = []
    var waiting: Set<Permission> { asked.filter { center?.state($0) != .denied } }

    @ObservationIgnored weak var center: PermissionCenter?

    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored let games: any GameActivity
    @ObservationIgnored let relauncher: any Relauncher
    @ObservationIgnored let pollInterval: Duration
    @ObservationIgnored let giveUpAfter: Duration
    @ObservationIgnored var now: () -> Date = Date.init
    @ObservationIgnored private var cancelled = false

    static let routeKey = "relaunch.route"
    static let savedKey = "relaunch.saved"
    // macOS's Quit & Reopen can come minutes after the prompt, while the user is in System Settings
    static let maxAge: TimeInterval = 15 * 60

    init(
        defaults: UserDefaults = .standard,
        center: PermissionCenter? = nil,
        games: any GameActivity = RunnerGameActivity(),
        relauncher: any Relauncher = LiveRelauncher(),
        pollInterval: Duration = .seconds(2),
        giveUpAfter: Duration = .seconds(31)
    ) {
        self.defaults = defaults
        self.center = center
        self.games = games
        self.relauncher = relauncher
        self.pollInterval = pollInterval
        self.giveUpAfter = giveUpAfter
    }

    func save(_ route: ScreenRoute) {
        guard let data = try? JSONEncoder().encode(route) else { return }
        defaults.set(data, forKey: Self.routeKey)
        defaults.set(now().timeIntervalSince1970, forKey: Self.savedKey)
    }

    func restore() -> ScreenRoute? {
        defer {
            defaults.removeObject(forKey: Self.routeKey)
            defaults.removeObject(forKey: Self.savedKey)
        }
        guard let data = defaults.data(forKey: Self.routeKey),
              now().timeIntervalSince1970 - defaults.double(forKey: Self.savedKey) < Self.maxAge
        else { return nil }
        return try? JSONDecoder().decode(ScreenRoute.self, from: data)
    }

    func watch(_ flow: PermissionFlow, route: @escaping @MainActor () -> ScreenRoute?) {
        flow.beforePrompt = { [weak self] permission in
            guard permission.needsRelaunch, let route = route() else { return }
            self?.save(route)
        }
    }

    func markWaiting(_ permission: Permission) {
        asked.insert(permission)
    }

    var banner: Banner? {
        let why = waiting.contains(.inputMonitoring)
            ? String(localized: "macOS applies Input Monitoring after a relaunch.") : nil
        switch phase {
        case .waitingForGame:
            return Banner(
                title: String(localized: "Cartouche relaunches when your game quits"),
                message: why,
                button: String(localized: "Cancel"))
        case .idle where !waiting.isEmpty:
            return Banner(
                title: String(localized: "Relaunch Cartouche to finish"),
                message: [why, String(localized: "Your game and settings stay as they are.")]
                    .compactMap { $0 }.joined(separator: " "),
                button: String(localized: "Relaunch"))
        default:
            return nil
        }
    }

    // Never while a game started by Cartouche runs: it waits for the game to quit
    func relaunch(to route: ScreenRoute) async {
        guard phase == .idle else { return }
        cancelled = false
        save(route)
        while await games.isGameRunning() {
            if phase != .waitingForGame {
                phase = .waitingForGame
                AppLog.note("relaunch waits for the game to quit")
            }
            try? await Task.sleep(for: pollInterval)
            if cancelled {
                phase = .idle
                _ = restore()
                return
            }
        }
        phase = .relaunching
        guard relauncher.relaunch() else {
            phase = .idle
            _ = restore()
            return
        }
        let giveUp = giveUpAfter
        Task {
            try? await Task.sleep(for: giveUp)
            guard phase == .relaunching else { return }
            phase = .idle
            _ = restore()
        }
    }

    func cancel() {
        cancelled = true
    }
}

struct RelaunchBanner: View {

    let service: RelaunchService
    let route: ScreenRoute

    var body: some View {
        if let banner = service.banner {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(banner.title)
                        .font(.headline)
                    if let message = banner.message {
                        Text(message)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 12)
                Button(banner.button) {
                    if service.phase == .waitingForGame {
                        service.cancel()
                    } else {
                        Task { await service.relaunch(to: route) }
                    }
                }
            }
            .padding(12)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}
