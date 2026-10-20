
import Foundation

enum GameVersion: String, Codable, Sendable, CaseIterable, Identifiable {
    case mac, windows

    var id: String { rawValue }

    var label: String {
        switch self {
        case .mac: String(localized: "Mac Version")
        case .windows: String(localized: "Windows Version")
        }
    }
}

struct SetupDefaults: Equatable, Sendable {
    var runnerID: String?
    var graphics: GraphicsBackend?
    var translation: GameSetupChoice.Translation?

    static let runnerKey = "setup.default.runner"
    static let graphicsKey = "setup.default.graphics"
    static let translationKey = "setup.default.translation"

    static func load(_ defaults: UserDefaults = .standard) -> SetupDefaults {
        SetupDefaults(
            runnerID: defaults.string(forKey: runnerKey),
            graphics: defaults.string(forKey: graphicsKey).flatMap(GraphicsBackend.init(rawValue:)),
            translation: defaults.string(forKey: translationKey).flatMap(GameSetupChoice.Translation.init(rawValue:)))
    }

    func save(_ defaults: UserDefaults = .standard) {
        for (key, value) in [(Self.runnerKey, runnerID), (Self.graphicsKey, graphics?.rawValue),
                             (Self.translationKey, translation?.rawValue)] {
            if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
    }
}

struct BackendAvailability: Equatable, Sendable {
    // Runners whose own files carry D3DMetal: a CrossOver with lib64/apple_gptk, or the user's Game Porting Toolkit copy.
    var d3dMetalRunners: Set<String> = []
    var installed: Set<GraphicsBackend> = []
    // Wine builds from CodeWeavers' sources, which DXMT needs (its winemetal unix library calls into CrossOver's winemac.drv).
    var crossOverWine: Set<String> = []

    // Never read from a runner source directly.
    static func current(
        registry: RunnerRegistry, runners: URL = SupportPaths.runners, backends: URL = BackendInstaller.folder,
        manifest: RunnerManifest = .current()
    ) -> BackendAvailability {
        var out = BackendAvailability()
        for runner in registry.runners where runner.isInstalled {
            switch runner.kind {
            case .crossOver:
                let root = SupportPaths.clonedRoot(forBuild: runner.id, runners: runners)
                if RunnerRegistry.crossOverD3DMetal(inRoot: root) != nil { out.d3dMetalRunners.insert(runner.id) }
            case .portingToolkit:
                if runner.state == .ready { out.d3dMetalRunners.insert(runner.id) }
            case .wineBuild:
                if manifest.build(id: runner.id)?.origin == .cartouche { out.crossOverWine.insert(runner.id) }
            }
        }
        out.installed = Set(BackendInstaller.installed(in: backends).map(\.backend))
        return out
    }
}

enum BackendSupport {

    static let preference: [GraphicsBackend] = [.d3dmetal, .dxmt, .dxvk, .wined3d]

    static func translations(for runner: Runner) -> [GameSetupChoice.Translation] {
        // Runner.flavors already leaves FEX out before macOS 26
        runner.flavors.map { $0 == .fex ? .fex : .rosetta }
    }

    // CrossOver ships DXMT, DXVK and wined3d; D3DMetal only where its copy has it, never on arm64 Wine (the run script drops it).
    static func crossOver(translation: GameSetupChoice.Translation, d3dMetal: Bool) -> [GraphicsBackend] {
        preference.filter { $0 != .d3dmetal || (d3dMetal && translation == .rosetta) }
    }

    static func backends(
        for runner: Runner, translation: GameSetupChoice.Translation, availability: BackendAvailability
    ) -> [GraphicsBackend] {
        let d3dMetal = availability.d3dMetalRunners.contains(runner.id) && translation == .rosetta
        let offered: Set<GraphicsBackend>
        switch runner.kind {
        case .crossOver:
            offered = Set(crossOver(translation: translation, d3dMetal: d3dMetal))
        case .wineBuild:
            var set: Set<GraphicsBackend> = [.wined3d]
            if availability.installed.contains(.dxvk) { set.insert(.dxvk) }
            if availability.installed.contains(.dxmt) && availability.crossOverWine.contains(runner.id)
                && translation == .rosetta { set.insert(.dxmt) }
            offered = set
        case .portingToolkit:
            // The toolkit is D3DMetal itself
            offered = d3dMetal ? [.d3dmetal] : []
        }
        return preference.filter(offered.contains)
    }
}

struct GameSetup: Equatable, Sendable {
    var version: GameVersion
    var runner: Runner?
    var translation: GameSetupChoice.Translation
    var backend: GraphicsBackend?
    var environment: [String: String]
    var metalHUD: Bool
}

enum GameSetupResolver {

    enum Problem: Hashable, Sendable {
        case runnerUnavailable(String)
        case translationUnavailable(GameSetupChoice.Translation)
        case backendUnavailable(GraphicsBackend)
        case variableRefused(String)
    }

    struct Resolution: Equatable, Sendable {
        var setup: GameSetup
        var problems: [Problem]
    }

    static let allowedPrefixes = ["D3DM_", "DXMT_", "DXVK_", "MTL_", "ROSETTA_"]

    static func isAllowed(name: String, value: String) -> Bool {
        guard let prefix = allowedPrefixes.first(where: name.hasPrefix), name.count > prefix.count, name.count <= 64
        else { return false }
        let nameOK = name.unicodeScalars.allSatisfy { ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "_" }
        let valueOK = value.count <= 256 && !value.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f }
        return nameOK && valueOK
    }

    static func resolve(
        _ choice: GameSetupChoice, defaults: SetupDefaults = SetupDefaults(), runners: [Runner],
        availability: BackendAvailability, hasMacBuild: Bool = false, offered: [Runner]? = nil
    ) -> Resolution {
        var problems: [Problem] = []
        let offered = offered ?? runners.filter(\.isOffered)

        let wanted = choice.runnerID ?? defaults.runnerID
        let runner = wanted.flatMap { id in offered.first { $0.id == id } } ?? offered.first
        if let id = choice.runnerID, runner?.id != id { problems.append(.runnerUnavailable(id)) }

        var translation = choice.translation ?? defaults.translation ?? .rosetta
        if let runner {
            let possible = BackendSupport.translations(for: runner)
            if !possible.contains(translation) {
                if choice.translation == translation { problems.append(.translationUnavailable(translation)) }
                translation = possible.first ?? .rosetta
            }
        }

        var backend: GraphicsBackend?
        if let runner {
            let possible = BackendSupport.backends(for: runner, translation: translation, availability: availability)
            let pick = choice.graphics ?? defaults.graphics ?? possible.first
            if let pick, possible.contains(pick) {
                backend = pick
            } else {
                if let wanted = choice.graphics { problems.append(.backendUnavailable(wanted)) }
                backend = possible.first
            }
        }

        var environment: [String: String] = [:]
        for (name, value) in (choice.environment ?? [:]).sorted(by: { $0.key < $1.key }) {
            if isAllowed(name: name, value: value) { environment[name] = value } else { problems.append(.variableRefused(name)) }
        }
        let metalHUD = choice.metalHUD ?? false
        if metalHUD { environment["MTL_HUD_ENABLED"] = "1" }

        let version: GameVersion = hasMacBuild ? (choice.version ?? .mac) : .windows
        return Resolution(
            setup: GameSetup(version: version, runner: runner, translation: translation, backend: backend,
                             environment: environment, metalHUD: metalHUD),
            problems: problems)
    }
}
