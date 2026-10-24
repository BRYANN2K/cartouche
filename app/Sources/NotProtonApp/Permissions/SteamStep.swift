
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
        // Steam is NotProton's to hand over: the row offers Replace NotProton
        case notProton
        // Steam's dylib is not the recorded one: the row offers Repair
        case needsRepair
        // Set up before: the app puts its build back on its own, so the row has no button
        case updatesItself
    }

    private(set) var phase: Phase = .idle
    @ObservationIgnored var beforeInstall: @MainActor () async throws -> Void = {}
    @ObservationIgnored var didSetUp: @MainActor () -> Void = {}

    @ObservationIgnored let flow: PermissionFlow
    @ObservationIgnored let install: @MainActor () async throws -> Void
    @ObservationIgnored let replace: (@MainActor () async throws -> Void)?
    @ObservationIgnored let usesNotProton: (@Sendable () -> Bool)?
    @ObservationIgnored let repair: (@MainActor () async throws -> Void)?
    @ObservationIgnored let needsRepair: (@MainActor () -> Bool)?
    @ObservationIgnored let updatesItself: (@MainActor () -> Bool)?
    @ObservationIgnored let upkeepFailed: (@MainActor () -> Bool)?
    @ObservationIgnored var relaunch: @MainActor (ScreenRoute) -> Void
    @ObservationIgnored private var visitedSettings = false

    init(
        flow: PermissionFlow,
        install: @escaping @MainActor () async throws -> Void,
        relaunch: @escaping @MainActor (ScreenRoute) -> Void,
        replace: (@MainActor () async throws -> Void)? = nil,
        usesNotProton: (@Sendable () -> Bool)? = nil,
        repair: (@MainActor () async throws -> Void)? = nil,
        needsRepair: (@MainActor () -> Bool)? = nil,
        updatesItself: (@MainActor () -> Bool)? = nil,
        upkeepFailed: (@MainActor () -> Bool)? = nil
    ) {
        self.flow = flow
        self.install = install
        self.relaunch = relaunch
        self.replace = replace
        self.usesNotProton = usesNotProton
        self.repair = repair
        self.needsRepair = needsRepair
        self.updatesItself = updatesItself
        self.upkeepFailed = upkeepFailed
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
        case .notProton:
            String(localized: "Steam uses NotProton. Cartouche replaces it inside Steam. NotProton's app and data stay on this Mac. To switch back, remove Cartouche and install NotProton again.")
        case .needsRepair: String(localized: "Cartouche in Steam needs a repair.")
        case .updatesItself: SteamUpkeep.automaticMessage
        }
    }

    func setUp() {
        flow.start(.appManagement, context: .onboarding, attempt: { [weak self] in
            await self?.attempt() ?? .unknown
        }) { _ in }
    }

    // The row appears, or an install failed on NotProton's insert: offer the takeover or the repair
    func refresh() {
        guard phase == .idle else { return }
        if usesNotProton?() == true {
            phase = .notProton
        } else if updatesItself?() == true {
            phase = .updatesItself
        } else if needsRepair?() == true {
            phase = .needsRepair
        }
    }

    // Read in the row's body, so the row follows the upkeep's observable state
    var upkeepRunning: Bool { updatesItself?() ?? false }

    // The upkeep finished: the installed state, or its failure with Try Again
    func followUpkeep() {
        guard phase == .updatesItself, !upkeepRunning else { return }
        if upkeepFailed?() == true {
            phase = needsRepair?() == true && repair != nil ? .needsRepair : .failed(SteamUpkeep.failedMessage)
        } else {
            phase = .done
        }
    }

    func replaceNotProton() {
        guard let replace else { return }
        flow.start(.appManagement, context: .onboarding, attempt: { [weak self] in
            await self?.attempt(using: replace) ?? .unknown
        }) { _ in }
    }

    // The same repair as Settings > Steam: this app's build goes into Steam and its record is rewritten
    func repairInSteam() {
        guard let repair else { return }
        flow.start(.appManagement, context: .onboarding, attempt: { [weak self] in
            await self?.attempt(using: repair) ?? .unknown
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
        relaunch(.onboarding(step: ScreenRoute.storesStep))
    }

    private func attempt() async -> PermissionState {
        await attempt(using: install)
    }

    private func attempt(using work: @MainActor () async throws -> Void) async -> PermissionState {
        let looksAllowed = center.state(.appManagement) == .allowed
        phase = .working
        do {
            try await beforeInstall()
            try await work()
            center.record(.allowed, for: .appManagement)
            phase = .done
            didSetUp()
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
            if usesNotProton?() == true {
                phase = .notProton
            } else if updatesItself?() == true {
                phase = .updatesItself
            } else if needsRepair?() == true, repair != nil {
                phase = .needsRepair
            } else {
                phase = .failed(error.localizedDescription)
            }
            return .unknown
        }
    }
}

struct SteamStepRow: View {

    @Bindable var step: SteamStep

    var body: some View {
        StatusRow(
            title: String(localized: "Cartouche in Steam"),
            tone: tone,
            detail: step.detail,
            secondaryAction: secondary,
            action: primary
        )
        .permissionExplanations(step.flow)
        .task {
            step.refresh()
            step.followUpkeep()
        }
        .onChange(of: step.upkeepRunning) { step.followUpkeep() }
    }

    private var tone: StatusTone? {
        switch step.phase {
        case .done: .ok
        case .blocked, .notApplied, .failed, .notProton, .needsRepair: .warning
        case .idle, .working, .updatesItself: nil
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
        case .notProton:
            StatusAction(label: String(localized: "Replace NotProton"), isProminent: true) {
                step.replaceNotProton()
            }
        case .needsRepair:
            StatusAction(label: String(localized: "Repair"), isProminent: true) {
                step.repairInSteam()
            }
        case .done, .updatesItself: nil
        }
    }
}
