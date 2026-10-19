// Where the first launch is and what the user chose so far. Saved after every
// change, so a quit midway reopens on the same step with the same choices.

import Foundation

enum OnboardingStep: String, Codable, CaseIterable, Sendable, Comparable {
    // The raw values are the ScreenRoute detail a relaunch reopens on
    case welcome
    case pcGames
    case consoles
    case folders
    case ready

    var title: String {
        switch self {
        case .welcome: String(localized: "Welcome")
        case .pcGames: String(localized: "PC games")
        case .consoles: String(localized: "Consoles")
        case .folders: String(localized: "Folders and privacy")
        case .ready: String(localized: "Ready")
        }
    }

    var index: Int { Self.allCases.firstIndex(of: self) ?? 0 }
    var next: OnboardingStep? { index + 1 < Self.allCases.count ? Self.allCases[index + 1] : nil }
    var previous: OnboardingStep? { index > 0 ? Self.allCases[index - 1] : nil }

    static func < (a: OnboardingStep, b: OnboardingStep) -> Bool { a.index < b.index }
}

struct OnboardingState: Codable, Equatable, Sendable {
    var step: OnboardingStep = .welcome
    // Console IDs from ConsoleCatalog, picked in the Consoles step
    var consoles: [String] = []
    // Set once the user changes the picks, so found consoles no longer pick themselves
    var consolesChosen = false
    // Consoles whose cores were downloaded during onboarding
    var addedConsoles: [String] = []
    // Game folders offered in Folders and privacy, and whether each is kept
    var folders: [String: Bool] = [:]
    // Done or skipped: the first launch is over
    var finished = false
}

struct OnboardingStore: @unchecked Sendable {
    let defaults: UserDefaults

    static let key = "onboarding.state"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // Nil before the first launch
    func load() -> OnboardingState? {
        defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(OnboardingState.self, from: $0) }
    }

    func save(_ state: OnboardingState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
