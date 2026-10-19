// An option that needs a permission. When the permission is denied the option
// turns back off and says why, where the user is, and how to fix it.

import Foundation
import Observation
import SwiftUI

extension Permission {
    // Names the permission and the fix
    var deniedMessage: String {
        switch self {
        case .appManagement: String(localized: "macOS blocked the change. Allow Cartouche in App Management, then try again.")
        case .steamInput: String(localized: "Steam can't read controllers. Allow Steam in Accessibility in System Settings.")
        case .accessibility: String(localized: "Cartouche can't press keys for the controller. Allow Accessibility in System Settings.")
        case .gameInputMonitoring: String(localized: "This game can't read the keyboard. Allow it in Input Monitoring in System Settings.")
        case .inputMonitoring: String(localized: "Cartouche can't read the keyboard. Allow Input Monitoring in System Settings.")
        case .downloads: String(localized: "Cartouche can't read Downloads. Allow it in System Settings.")
        case .removableVolumes: String(localized: "Cartouche can't read this disk. Allow Removable Volumes in System Settings.")
        case .localNetwork: String(localized: "Cartouche can't use the local network. Allow Local Network in System Settings.")
        case .notifications: String(localized: "Notifications are off for Cartouche. Allow them in System Settings.")
        case .loginItems: String(localized: "Cartouche can't open at login. Allow it in Login Items in System Settings.")
        case .keychain: String(localized: "Cartouche can't use the keychain. Sign in again.")
        }
    }

    // What keeps working without the permission
    var stillWorks: String? {
        switch self {
        case .appManagement: String(localized: "Console games and the rest of Cartouche still work.")
        case .steamInput: String(localized: "Steam games still run.")
        case .inputMonitoring: String(localized: "Left ⌘ as Ctrl still works.")
        case .downloads: String(localized: "Dragging an installer onto Cartouche still works.")
        case .removableVolumes: String(localized: "The folder shows as unavailable until then.")
        case .localNetwork: String(localized: "Netplay over the internet still works.")
        case .notifications: String(localized: "Progress still shows in Cartouche.")
        case .accessibility, .gameInputMonitoring, .loginItems, .keychain: nil
        }
    }
}

@MainActor
@Observable
final class GatedOption {

    enum Phase: Equatable {
        case off
        case on
        case waitingForRelaunch
        case denied
    }

    let permission: Permission
    @ObservationIgnored let flow: PermissionFlow
    @ObservationIgnored let context: PermissionFlow.Context
    @ObservationIgnored var target: URL?
    // Told when the permission waits for Cartouche to relaunch
    @ObservationIgnored var onWaitingForRelaunch: (@MainActor (Permission) -> Void)?
    private var chosen: Phase

    init(_ permission: Permission, flow: PermissionFlow, context: PermissionFlow.Context = .app, isOn: Bool = false) {
        self.permission = permission
        self.flow = flow
        self.context = context
        chosen = isOn ? .on : .off
    }

    // A refusal made in System Settings while Cartouche waited shows up here too
    var phase: Phase {
        let state = flow.center.state(permission)
        switch chosen {
        case .off: return .off
        // Fixed in System Settings: the message goes, and the user turns the option on again
        case .denied: return state == .allowed ? .off : .denied
        case .on, .waitingForRelaunch: return state == .denied ? .denied : chosen
        }
    }

    var isOn: Bool { phase == .on }

    var status: String? {
        switch phase {
        case .waitingForRelaunch: String(localized: "Waiting for a relaunch")
        case .denied: permission.deniedMessage
        case .on, .off: nil
        }
    }

    func set(_ on: Bool) {
        guard on else {
            chosen = .off
            return
        }
        flow.start(permission, context: context, target: target) { [weak self] outcome in
            self?.apply(outcome)
        }
    }

    // After a relaunch, the permission is there and the option turns on without asking
    func finishAfterRelaunch() {
        if flow.center.state(permission) == .allowed { chosen = .on }
    }

    // The feature found out by itself, as a failed Downloads read does
    func reportDenied() {
        flow.center.record(.denied, for: permission, target: target)
        chosen = .denied
    }

    private func apply(_ outcome: PermissionFlow.Outcome) {
        switch outcome {
        case .allowed: chosen = .on
        case .denied: chosen = .denied
        case .notNow, .refused: chosen = .off
        case .pending:
            if permission.needsRelaunch {
                chosen = .waitingForRelaunch
                onWaitingForRelaunch?(permission)
            } else {
                // No answer to read, as with Local Network: the feature reports a refusal when it meets one
                chosen = .on
            }
        }
    }
}

struct GatedOptionRow: View {

    @Bindable var option: GatedOption
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            StatusRow(
                title: title,
                value: option.status ?? subtitle,
                toggle: Binding(get: { option.isOn }, set: { option.set($0) })
            )
            if option.phase == .denied {
                HStack(alignment: .firstTextBaseline) {
                    if let stillWorks = option.permission.stillWorks {
                        Text(stillWorks)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(Remedy.settingsButton) { option.flow.center.openSettings(for: option.permission) }
                }
                .padding(.leading, StatusMetrics.textInset)
            }
        }
        .permissionExplanations(option.flow)
    }
}
