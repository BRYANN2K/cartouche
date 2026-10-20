
import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class SteamStep {

    enum Phase: Equatable {
        case idle
        case working
        case blocked(Remedy)
        case notApplied
        case failed(String)
        case done
    }

    private(set) var phase: Phase = .idle

    @ObservationIgnored let flow: PermissionFlow
    @ObservationIgnored let install: @MainActor () async throws -> Void
    @ObservationIgnored var relaunch: @MainActor (ScreenRoute) -> Void
    @ObservationIgnored private var visitedSettings = false

    init(
        flow: PermissionFlow,
        install: @escaping @MainActor () async throws -> Void,
        relaunch: @escaping @MainActor (ScreenRoute) -> Void
    ) {
        self.flow = flow
        self.install = install
        self.relaunch = relaunch
    }

    private var center: PermissionCenter { flow.center }

    var canContinue: Bool { phase != .working }

    var detail: String {
        switch phase {
        case .idle, .working: String(localized: "Cartouche adds its tools to the Steam app")
        case .blocked(let remedy):
            remedy == .appManagement ? Permission.appManagement.deniedMessage : remedy.advice
        case .notApplied:
            String(localized: "macOS still blocks the change. If you allowed Cartouche in App Management, relaunch Cartouche to finish.")
        case .failed(let message): message
        case .done: String(localized: "Steam lists Cartouche's compatibility tools")
        }
    }

    func setUp() {
        flow.start(.appManagement, context: .onboarding, attempt: { [weak self] in
            await self?.attempt() ?? .unknown
        }) { _ in }
    }

    func tryAgain() async {
        _ = await attempt()
    }

    func openSettings() {
        visitedSettings = true
        center.openSettings(for: .appManagement)
    }

    func relaunchCartouche() {
        relaunch(.onboarding(step: ScreenRoute.pcGamesStep))
    }

    private func attempt() async -> PermissionState {
        let looksAllowed = center.state(.appManagement) == .allowed
        phase = .working
        do {
            try await install()
            center.record(.allowed, for: .appManagement)
            phase = .done
            return .allowed
        } catch let refusal as WriteRefused {
            let remedy = refusal.remedy
            AppLog.note("steam step refused: \(refusal.path)")
            guard remedy == .appManagement else {
                phase = .blocked(remedy)
                return .unknown
            }
            center.record(.denied, for: .appManagement)
            phase = looksAllowed || visitedSettings ? .notApplied : .blocked(.appManagement)
            return .denied
        } catch {
            phase = .failed(error.localizedDescription)
            return .unknown
        }
    }
}

struct SteamStepRow: View {

    @Bindable var step: SteamStep

    var body: some View {
        StatusRow(
            title: String(localized: "Steam Play in Steam"),
            tone: tone,
            detail: step.detail,
            secondaryAction: secondary,
            action: primary
        )
        .permissionExplanations(step.flow)
    }

    private var tone: StatusTone? {
        switch step.phase {
        case .done: .ok
        case .blocked, .notApplied, .failed: .warning
        case .idle, .working: nil
        }
    }

    private var secondary: StatusAction? {
        switch step.phase {
        case .blocked(.appManagement), .notApplied:
            StatusAction(label: Remedy.settingsButton) { step.openSettings() }
        default: nil
        }
    }

    private var primary: StatusAction? {
        switch step.phase {
        case .idle:
            StatusAction(label: String(localized: "Set Up"), isProminent: true) { step.setUp() }
        case .working:
            StatusAction(label: String(localized: "Set Up"), isProminent: true, isEnabled: false) {}
        case .blocked, .failed:
            StatusAction(label: String(localized: "Try Again"), isProminent: true) {
                Task { await step.tryAgain() }
            }
        case .notApplied:
            StatusAction(label: String(localized: "Relaunch Cartouche"), isProminent: true) {
                step.relaunchCartouche()
            }
        case .done: nil
        }
    }
}
