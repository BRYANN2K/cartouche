// The app's view of every permission: reads states, asks macOS when a flow
// tells it to, and opens System Settings for recovery.

import AppKit
import Foundation
import Observation

// Shows the macOS prompt. Never called before Cartouche's explanation.
protocol PermissionRequester: Sendable {
    func request(_ permission: Permission, target: URL?) async -> SystemAnswer
}

@MainActor
@Observable
final class PermissionCenter {

    private(set) var states: [Permission: PermissionState] = [:]

    @ObservationIgnored let probe: any PermissionProbe
    @ObservationIgnored let requester: any PermissionRequester
    @ObservationIgnored let ledger: PermissionLedger
    @ObservationIgnored var opener: @MainActor (URL) -> Bool
    @ObservationIgnored var system: OperatingSystemVersion
    @ObservationIgnored private var activation: (any NSObjectProtocol)?
    @ObservationIgnored private let notifications: NotificationCenter

    init(
        probe: any PermissionProbe,
        requester: any PermissionRequester,
        ledger: PermissionLedger = PermissionLedger(),
        opener: @escaping @MainActor (URL) -> Bool,
        system: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
        notifications: NotificationCenter = .default
    ) {
        self.probe = probe
        self.requester = requester
        self.ledger = ledger
        self.opener = opener
        self.system = system
        self.notifications = notifications
    }

    func state(_ permission: Permission) -> PermissionState {
        states[permission] ?? .notAsked
    }

    func refresh() async {
        for permission in Permission.allCases {
            states[permission] = await read(permission, deep: false)
        }
    }

    // Back from System Settings: check again what the user went there to change
    func applicationDidBecomeActive() async {
        for permission in Permission.allCases {
            states[permission] = await read(permission, deep: ledger.wantsRecheck(permission))
        }
    }

    func watchActivation() {
        guard activation == nil else { return }
        activation = notifications.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.applicationDidBecomeActive() }
        }
    }

    private func read(_ permission: Permission, deep: Bool) async -> PermissionState {
        let answer = await probe.answer(for: permission, deep: deep, target: ledger.target(permission))
        let state = permission.state(
            answer: answer, asked: ledger.wasAsked(permission), last: ledger.last(permission))
        if deep && answer != .unreadable { ledger.setRecheck(false, for: permission) }
        if answer == .granted || answer == .denied { ledger.note(state, for: permission) }
        return state
    }

    // Only PermissionFlow calls this, after its explanation
    func request(_ permission: Permission, target: URL? = nil) async -> PermissionState {
        ledger.noteAsked(permission)
        if let target { ledger.setTarget(target, for: permission) }
        let answer = await requester.request(permission, target: target)
        let state = permission.state(answer: answer, asked: true, last: ledger.last(permission))
        if answer == .granted || answer == .denied { ledger.note(state, for: permission) }
        states[permission] = state
        return state
    }

    // A feature's own attempt showed the answer, as App Management's write refusal does
    func record(_ state: PermissionState, for permission: Permission, target: URL? = nil) {
        if let target { ledger.setTarget(target, for: permission) }
        ledger.note(state, for: permission)
        states[permission] = state
    }

    @discardableResult
    func openSettings(for permission: Permission) -> Bool {
        ledger.setRecheck(true, for: permission)
        AppLog.note("opening System Settings for \(permission.rawValue)")
        let links = SettingsLink.urls(for: permission, on: system)
        return links.contains { opener($0) }
    }
}
