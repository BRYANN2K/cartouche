import Foundation

// Status checks are read-only. Steam integration changes require a manual action in Settings.
enum SteamUpkeep {

    enum Decision: Equatable, Sendable {
        case installNow
        case waitForQuit
        case nothing
        // The automatic run failed: Settings > Steam shows the error and the manual action
        case manual
    }

    enum State: Equatable, Sendable {
        case idle
        case waitingForQuit
        case due
        case updating
        case failed
    }

    // True after an install the user started; false after Repair Steam, Remove Everything or another Steam
    static let setUpKey = "steam.integrationSetUp"

    static func wasSetUp(_ snapshot: StatusSnapshot, defaults: UserDefaults) -> Bool {
        if let recorded = defaults.object(forKey: setUpKey) as? Bool { return recorded }
        // Installs from before the flag: this app's build record, and Steam still names Cartouche's dylib
        guard snapshot.buildRecorded else { return false }
        switch snapshot.steam {
        case .installed, .outdated: return true
        default: return false
        }
    }

    // Cartouche's files in Steam are missing or are not this app's build
    static func needsInstall(_ snapshot: StatusSnapshot) -> Bool {
        switch snapshot.steam {
        case .notInstalled, .installed, .outdated: break
        case .steamMissing, .foreign, .notProton: return false
        }
        switch snapshot.installContent {
        case .newerInstalled, .unavailable: return false
        case .update, .repair, .unrecorded, .mismatchedDylib: return true
        case .unchecked, .current: break
        }
        if case .installed = snapshot.steam { return !snapshot.payload.isSteamComplete }
        return true
    }

    static func decide(setUpBefore: Bool, failedBefore: Bool, snapshot: StatusSnapshot) -> Decision {
        guard setUpBefore, needsInstall(snapshot) else { return .nothing }
        return .manual
    }

    static func state(for decision: Decision) -> State {
        switch decision {
        case .installNow: .due
        case .waitForQuit: .waitingForQuit
        case .nothing: .idle
        case .manual: .idle
        }
    }

    static let waitingMessage = String(localized: "Cartouche will update its Steam integration when Steam quits.")
    static let failedMessage = String(localized: "Cartouche could not update its Steam integration. Settings > Steam shows the error and lets you try again.")
    static let automaticMessage = String(localized: "Cartouche updates its Steam integration automatically.")
}
