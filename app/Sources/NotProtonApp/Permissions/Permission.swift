
import Foundation

enum Permission: String, CaseIterable, Identifiable, Codable, Sendable {
    case appManagement
    case steamInput
    case accessibility
    case gameInputMonitoring
    case inputMonitoring
    case downloads
    case removableVolumes
    case localNetwork
    case notifications
    case loginItems
    case keychain

    var id: String { rawValue }

    enum Holder: Sendable {
        case cartouche, steam, games
    }

    var holder: Holder {
        switch self {
        case .steamInput: .steam
        case .gameInputMonitoring: .games
        default: .cartouche
        }
    }

    enum Moment: Sendable, Equatable {
        case onboardingSteamStep
        case steamFirstLaunch
        case optionTurnedOn
        case gameNeedsIt
        case folderAdded
        case firstNetplay
        case afterFirstDownloadOrInstall
        case never
    }

    var moment: Moment {
        switch self {
        case .appManagement: .onboardingSteamStep
        case .steamInput: .steamFirstLaunch
        case .accessibility, .inputMonitoring, .downloads, .loginItems: .optionTurnedOn
        case .gameInputMonitoring: .gameNeedsIt
        case .removableVolumes: .folderAdded
        case .localNetwork: .firstNetplay
        case .notifications: .afterFirstDownloadOrInstall
        case .keychain: .never
        }
    }

    // macOS applies Input Monitoring to a running app only after it restarts
    var needsRelaunch: Bool { self == .inputMonitoring }

    // Onboarding v2 asks only the permissions earlier choices made necessary,
    // each with a one-sentence reason. App Management stays with the Steam row.
    var askedInOnboarding: Bool {
        switch self {
        case .appManagement, .downloads, .accessibility, .removableVolumes, .notifications: true
        default: false
        }
    }

    // Cartouche shows its own macOS prompt for these. App Management has none:
    // macOS blocks the first write and notifies.
    var hasPrompt: Bool {
        switch self {
        case .accessibility, .inputMonitoring, .downloads, .removableVolumes, .localNetwork, .notifications:
            true
        case .appManagement, .steamInput, .gameInputMonitoring, .loginItems, .keychain:
            false
        }
    }

    var title: String {
        switch self {
        case .appManagement: String(localized: "App Management")
        case .steamInput, .accessibility: String(localized: "Accessibility")
        case .gameInputMonitoring, .inputMonitoring: String(localized: "Input Monitoring")
        case .downloads: String(localized: "Downloads Folder")
        case .removableVolumes: String(localized: "Removable Volumes")
        case .localNetwork: String(localized: "Local Network")
        case .notifications: String(localized: "Notifications")
        case .loginItems: String(localized: "Login Items")
        case .keychain: String(localized: "Keychain")
        }
    }

    var feature: String {
        switch self {
        case .appManagement: String(localized: "Adds Steam Play to the Steam app")
        case .steamInput: String(localized: "Steam, for controllers in Steam games")
        case .accessibility: String(localized: "Controller for keyboard-only games")
        case .gameInputMonitoring: String(localized: "Windows games, for the keyboard in some games")
        case .inputMonitoring: String(localized: "Remap the Mac keyboard and mouse per game")
        case .downloads: String(localized: "Suggest installers that appear in Downloads")
        case .removableVolumes: String(localized: "Game folders on an external disk")
        case .localNetwork: String(localized: "Netplay and LAN games")
        case .notifications: String(localized: "Download finished, install finished, ready to play")
        case .loginItems: String(localized: "Open Cartouche at login")
        case .keychain: String(localized: "Store sign-ins for Epic, GOG, Amazon and RetroAchievements")
        }
    }
}

enum PermissionState: String, Codable, Sendable {
    case allowed
    case denied
    case notAsked
    // Asked, but macOS gives no way to read the answer without asking again
    case unknown

    var label: String {
        switch self {
        case .allowed: String(localized: "Allowed")
        case .denied: String(localized: "Not allowed")
        case .notAsked: String(localized: "Not asked yet")
        case .unknown: String(localized: "Unknown, will be asked when needed")
        }
    }
}

enum SystemAnswer: Sendable, Equatable {
    case granted
    case denied
    case undetermined
    // Not granted, and macOS does not say whether it was ever asked
    case notGranted
    // No API reads it without prompting
    case unreadable
}

extension Permission {
    func state(answer: SystemAnswer, asked: Bool, last: PermissionState?) -> PermissionState {
        if self == .keychain { return .allowed }
        switch answer {
        case .granted: return .allowed
        case .denied: return .denied
        case .undetermined: return asked ? (last ?? .unknown) : .notAsked
        case .notGranted: return asked ? .denied : .notAsked
        case .unreadable:
            if let last { return last }
            if holder != .cartouche { return .unknown }
            return asked ? .unknown : .notAsked
        }
    }
}
