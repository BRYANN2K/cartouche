
import Foundation

enum OnboardingStep: String, Codable, CaseIterable, Sendable, Comparable {
    // The raw values are the ScreenRoute detail a relaunch reopens on
    case welcome
    case windowsGames
    case stores
    case consoles
    case controller
    case permissions
    case ready

    var title: String {
        switch self {
        case .welcome: String(localized: "Welcome")
        case .windowsGames: String(localized: "Windows games")
        case .stores: String(localized: "Stores")
        case .consoles: String(localized: "Consoles")
        case .controller: String(localized: "Controller")
        case .permissions: String(localized: "Permissions and storage")
        case .ready: String(localized: "Ready")
        }
    }

    var index: Int { Self.allCases.firstIndex(of: self) ?? 0 }
    var next: OnboardingStep? { index + 1 < Self.allCases.count ? Self.allCases[index + 1] : nil }
    var previous: OnboardingStep? { index > 0 ? Self.allCases[index - 1] : nil }
    var skippable: Bool { self != .welcome && self != .ready }

    // A saved route from the v1 flow lands on the step that owns the same rows now
    static func route(_ raw: String) -> OnboardingStep? {
        switch raw {
        case "pcGames": .stores       // the Steam integration row moved to Stores
        case "folders": .permissions  // folder/privacy rows moved to Consoles + Permissions
        default: OnboardingStep(rawValue: raw)
        }
    }

    static func < (a: OnboardingStep, b: OnboardingStep) -> Bool { a.index < b.index }
}

struct OnboardingState: Codable, Equatable, Sendable {

    static let currentVersion = 2

    var version = OnboardingState.currentVersion
    var step: OnboardingStep = .welcome
    var consoles: [String] = []
    var consolesChosen = false
    var addedConsoles: [String] = []
    var folders: [String: Bool] = [:]
    var finished = false

    // v2 choices — everything stays editable in Settings afterwards
    var wantsRunner = true        // the free Cartouche Wine build is preselected
    var romFolder: String?        // optional folder to watch, picked on Consoles
    var watchDownloads = false     // suggest installers that finish downloading
    var controllerKeys = false     // play keyboard-only games with a controller
    var padGlyphs: String?        // PadFamily raw; nil = the connected controller's own
    var padPreset: String?        // ControllerLayout.Preset raw
    var runnerRequested = false
    var coreRequests: [String] = []
    var toolkitImage: String?
    var gamesFolder: String?      // installs location; nil = the default under Application Support

    init() {}

    // v1 payloads carry fewer fields and other step names: decode what still applies
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        let rawStep = try c.decodeIfPresent(String.self, forKey: .step) ?? OnboardingStep.welcome.rawValue
        step = OnboardingStep(rawValue: rawStep) ?? .welcome
        consoles = try c.decodeIfPresent([String].self, forKey: .consoles) ?? []
        consolesChosen = try c.decodeIfPresent(Bool.self, forKey: .consolesChosen) ?? false
        addedConsoles = try c.decodeIfPresent([String].self, forKey: .addedConsoles) ?? []
        folders = try c.decodeIfPresent([String: Bool].self, forKey: .folders) ?? [:]
        finished = try c.decodeIfPresent(Bool.self, forKey: .finished) ?? false
        wantsRunner = try c.decodeIfPresent(Bool.self, forKey: .wantsRunner) ?? true
        romFolder = try c.decodeIfPresent(String.self, forKey: .romFolder)
        watchDownloads = try c.decodeIfPresent(Bool.self, forKey: .watchDownloads) ?? false
        controllerKeys = try c.decodeIfPresent(Bool.self, forKey: .controllerKeys) ?? false
        padGlyphs = try c.decodeIfPresent(String.self, forKey: .padGlyphs)
        padPreset = try c.decodeIfPresent(String.self, forKey: .padPreset)
        gamesFolder = try c.decodeIfPresent(String.self, forKey: .gamesFolder)
        runnerRequested = try c.decodeIfPresent(Bool.self, forKey: .runnerRequested) ?? false
        coreRequests = try c.decodeIfPresent([String].self, forKey: .coreRequests) ?? []
        toolkitImage = try c.decodeIfPresent(String.self, forKey: .toolkitImage)
    }
}

struct OnboardingStore: @unchecked Sendable {
    let defaults: UserDefaults

    static let key = "onboarding.state"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> OnboardingState? {
        guard let data = defaults.data(forKey: Self.key),
              let decoded = try? JSONDecoder().decode(OnboardingState.self, from: data) else { return nil }
        let state = Self.migrate(decoded)
        if state != decoded { save(state) }
        return state
    }

    // A v1 user who finished stays finished and never sees v2; a v1 run left
    // mid-way starts v2 at Welcome, keeping only what still applies.
    private static func migrate(_ state: OnboardingState) -> OnboardingState {
        var state = state
        guard state.version < OnboardingState.currentVersion else { return state }
        state.version = OnboardingState.currentVersion
        if !state.finished { state.step = .welcome }
        return state
    }

    func save(_ state: OnboardingState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
