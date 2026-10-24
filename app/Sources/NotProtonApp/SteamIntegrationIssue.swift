import SwiftUI

/// One next step, derived only from the last captured status (never from live disk state).
enum SteamIntegrationIssue: Equatable {
    case steamMissing
    case notInstalled
    case otherIntegration
    case newerInstalled
    case unavailable
    case update
    case repair
    case missingTools
    case damagedTools
    // The upkeep installs this app's build once Steam quits; nothing to press
    case updatesWhenSteamQuits
    // The automatic run failed: Settings > Steam has the error and the manual action
    case automaticUpdateFailed

    static func current(in snapshot: StatusSnapshot?, upkeep: SteamUpkeep.State = .idle) -> Self? {
        guard let snapshot else { return nil }
        switch snapshot.steam {
        case .steamMissing: return .steamMissing
        case .notInstalled: return .notInstalled
        case .installed, .outdated: break
        default: return .otherIntegration
        }
        switch snapshot.installContent {
        case .newerInstalled: return .newerInstalled
        case .unavailable: return .unavailable
        case .update: return .update
        case .repair, .unrecorded, .mismatchedDylib: return .repair
        case .unchecked, .current: break
        }
        if case .outdated = snapshot.steam { return .update }
        guard snapshot.payload.isComplete else { return .repair }
        if !snapshot.damagedRunners.isEmpty { return .damagedTools }
        if case .unpatched = snapshot.runner { return .damagedTools }
        if snapshot.runners.contains(where: {
            if case .damaged = $0.state { return true }
            return false
        }) { return .damagedTools }
        // A discovered source (.available) is not a configured compatibility tool.
        let hasReadyRunner = snapshot.runners.contains { $0.isInstalled && $0.state == .ready }
        let hasInstalledBuild = !snapshot.installedRunners.isEmpty || !snapshot.runner.builds.isEmpty
        return hasReadyRunner || hasInstalledBuild || !snapshot.compatibilityTools.isEmpty ? nil : .missingTools
    }

    var message: String {
        switch self {
        case .steamMissing: String(localized: "Steam could not be found. Choose or install Steam in Settings.")
        case .notInstalled: String(localized: "Cartouche is not installed in Steam. Set it up in Settings.")
        case .otherIntegration: String(localized: "Another integration is installed in Steam. Review it in Settings before installing Cartouche.")
        case .newerInstalled: String(localized: "Steam has a newer Cartouche build. Use the Cartouche app that installed it.")
        case .unavailable: String(localized: "Cartouche could not verify its installed files. Review Steam Settings before continuing.")
        case .update: String(localized: "Steam’s Cartouche integration needs an update.")
        case .repair: String(localized: "Steam’s Cartouche integration has missing or changed files. Repair it in Settings.")
        case .missingTools: String(localized: "No compatibility tool is set up for Steam. Set one up in Settings.")
        case .damagedTools: String(localized: "A Steam compatibility tool needs repair. Review it in Settings.")
        case .updatesWhenSteamQuits: SteamUpkeep.waitingMessage
        case .automaticUpdateFailed: SteamUpkeep.failedMessage
        }
    }

    // Settings > Steam has its own Cartouche line, so only tool problems get a banner there
    var showsInSettings: Bool { self == .missingTools || self == .damagedTools }

    // A quiet status line, without a button
    var isQuiet: Bool { self == .updatesWhenSteamQuits }

    var settingsMessage: String {
        switch self {
        case .missingTools: String(localized: "No compatibility tool is set up for Steam yet.")
        case .damagedTools: String(localized: "A Steam compatibility tool needs repair.")
        default: message
        }
    }
}

struct SteamIntegrationBanner: View {
    var inSettings = false

    @Environment(SystemStatus.self) private var status: SystemStatus?
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if let issue = SteamIntegrationIssue.current(in: status?.snapshot, upkeep: status?.upkeep ?? .idle),
           !inSettings || issue.showsInSettings {
            row(issue)
        }
    }

    private func row(_ issue: SteamIntegrationIssue) -> some View {
        let tint: Color = issue.isQuiet ? .secondary : .orange
        return HStack(alignment: .center, spacing: 12) {
            Image(systemName: issue.isQuiet ? "info.circle" : "exclamationmark.triangle.fill")
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(verbatim: inSettings ? issue.settingsMessage : issue.message)
                .fixedSize(horizontal: false, vertical: true)
            if !issue.isQuiet { button }
        }
        .font(.callout)
        .buttonStyle(.pill)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: .infinity, alignment: inSettings ? .leading : .center)
        .padding(.vertical, inSettings ? 0 : 8)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var button: some View {
        if inSettings {
            Button("Runners…") {
                SettingsRoute.shared.tab = .compatibility
                openSettings()
            }
        } else {
            Button("Steam Settings…") {
                SettingsRoute.shared.tab = .steam
                openSettings()
            }
        }
    }
}
