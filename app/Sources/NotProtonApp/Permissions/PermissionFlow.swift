// Just in time: a feature asks for its permission when the user starts it.
// Cartouche explains in one sentence first, and only Continue reaches macOS.

import Foundation
import Observation

struct PermissionExplanation: Equatable, Sendable {
    let title: String
    let reason: String
    // Said before the prompt when macOS needs a relaunch to apply the permission
    var relaunch: String?
}

extension Permission {
    // nil for permissions Cartouche never asks for itself
    var explanation: PermissionExplanation? {
        switch self {
        case .appManagement:
            PermissionExplanation(
                title: String(localized: "Cartouche needs to change the Steam app"),
                reason: String(localized: "To add Steam Play, Cartouche modifies Steam, which macOS blocks until you allow Cartouche in App Management."))
        case .accessibility:
            PermissionExplanation(
                title: String(localized: "Allow Cartouche to press keys for your controller?"),
                reason: String(localized: "To play keyboard-only games with a controller, Cartouche turns buttons into key presses, which needs Accessibility."))
        case .inputMonitoring:
            PermissionExplanation(
                title: String(localized: "Allow Cartouche to read the keyboard?"),
                reason: String(localized: "To remap keys while a game runs, Cartouche needs Input Monitoring."),
                relaunch: String(localized: "macOS applies it after Cartouche relaunches, which takes a few seconds."))
        case .downloads:
            PermissionExplanation(
                title: String(localized: "Watch your Downloads folder?"),
                reason: String(localized: "Cartouche looks for Windows installers that finish downloading and suggests installing them."))
        case .removableVolumes:
            PermissionExplanation(
                title: String(localized: "Use games on an external disk?"),
                reason: String(localized: "To find and run the games in this folder, Cartouche needs to read the disk."))
        case .localNetwork:
            PermissionExplanation(
                title: String(localized: "Play with others on your network?"),
                reason: String(localized: "To host or join a game on your local network, Cartouche needs Local Network access."))
        case .notifications:
            PermissionExplanation(
                title: String(localized: "Get a notification when a game is ready?"),
                reason: String(localized: "Cartouche tells you when a download or an install finishes, even when its window is closed."))
        case .loginItems:
            PermissionExplanation(
                title: String(localized: "Open Cartouche at login?"),
                reason: String(localized: "macOS adds Cartouche to Login Items, where you can remove it at any time."))
        case .steamInput, .gameInputMonitoring, .keychain:
            nil
        }
    }
}

@MainActor
@Observable
final class PermissionFlow {

    enum Context: Sendable {
        case app
        case onboarding
    }

    enum Outcome: Equatable, Sendable {
        case allowed
        case denied
        case notNow
        // The answer comes later: in System Settings, or after a relaunch
        case pending
        // Not a permission this place may ask for
        case refused
    }

    struct Ask: Identifiable, Equatable {
        let permission: Permission
        let explanation: PermissionExplanation
        var id: Permission { permission }
    }

    private(set) var asking: Ask?

    @ObservationIgnored let center: PermissionCenter
    // Runs right before the macOS prompt. The relaunch service saves the screen here,
    // since macOS's Quit & Reopen comes with no warning.
    @ObservationIgnored var beforePrompt: (@MainActor (Permission) -> Void)?
    @ObservationIgnored private var pending: (
        target: URL?, attempt: (@MainActor () async -> PermissionState)?, finish: @MainActor (Outcome) -> Void
    )?

    init(center: PermissionCenter) {
        self.center = center
    }

    // `attempt` replaces the macOS prompt for App Management, whose only request is
    // the write itself.
    func start(
        _ permission: Permission,
        context: Context = .app,
        target: URL? = nil,
        attempt: (@MainActor () async -> PermissionState)? = nil,
        then finish: @escaping @MainActor (Outcome) -> Void
    ) {
        if context == .onboarding && (!permission.askedInOnboarding || permission.needsRelaunch) {
            AppLog.note("permission \(permission.rawValue) refused in onboarding")
            finish(.refused)
            return
        }
        guard let explanation = permission.explanation else {
            finish(.refused)
            return
        }
        switch center.state(permission) {
        case .allowed:
            // Nothing to explain: macOS will not block it
            if let attempt {
                Task { finish(Self.outcome(await attempt())) }
            } else {
                finish(.allowed)
            }
        case .denied where attempt == nil:
            // macOS will not ask again, so the feature shows how to fix it instead
            finish(.denied)
        default:
            notNow()
            pending = (target, attempt, finish)
            asking = Ask(permission: permission, explanation: explanation)
        }
    }

    func confirm() async {
        guard let ask = asking, let job = pending else { return }
        asking = nil
        pending = nil
        let state: PermissionState
        if let attempt = job.attempt {
            state = await attempt()
        } else {
            beforePrompt?(ask.permission)
            AppLog.note("asking macOS for \(ask.permission.rawValue)")
            state = await center.request(ask.permission, target: job.target)
        }
        job.finish(Self.outcome(state))
    }

    func notNow() {
        guard let job = pending else { return }
        asking = nil
        pending = nil
        job.finish(.notNow)
    }

    static func outcome(_ state: PermissionState) -> Outcome {
        switch state {
        case .allowed: .allowed
        case .denied: .denied
        case .notAsked, .unknown: .pending
        }
    }
}
