// Settings > Privacy: every permission, its state, and the way to change it.
// The Settings window that hosts it comes with P5.

import SwiftUI

struct PrivacyRow: Equatable, Identifiable {
    let permission: Permission
    let state: PermissionState

    var id: Permission { permission }
    var title: String { permission.title }
    var feature: String { permission.feature }
    // Not asked yet means macOS has no entry for Cartouche to change
    var canOpenSettings: Bool { state != .notAsked && !SettingsLink.urls(for: permission).isEmpty }

    var tone: StatusTone {
        switch state {
        case .allowed: .ok
        case .denied: .warning
        case .notAsked, .unknown: .neutral
        }
    }

    @MainActor
    static func rows(_ center: PermissionCenter) -> [PrivacyRow] {
        Permission.allCases.map { PrivacyRow(permission: $0, state: center.state($0)) }
    }
}

struct PrivacySettingsView: View {

    let center: PermissionCenter
    @Bindable var choices: PrivacyChoices = PrivacyChoices()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Toggle("Fetch Mac reports from MacGamingDB", isOn: $choices.fetchMacReports)
                Text("When you open a game, Cartouche asks MacGamingDB for its Mac reports. MacGamingDB sees which game, but no account or Mac identifier.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // Frame rates stay on this Mac in v0.1.0: sharing (P8 payload) has no UI until v0.1.1
                Divider()
                Text("Cartouche asks for a permission the first time you use the feature that needs it.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(PrivacyRow.rows(center)) { row in
                    StatusRow(
                        title: row.title,
                        value: row.feature,
                        tone: row.tone,
                        trailing: row.state.label,
                        action: row.canOpenSettings
                            ? StatusAction(label: Remedy.settingsButton) { center.openSettings(for: row.permission) }
                            : nil
                    )
                }
            }
            .padding(20)
        }
        .task {
            center.watchActivation()
            await center.refresh()
        }
    }
}
