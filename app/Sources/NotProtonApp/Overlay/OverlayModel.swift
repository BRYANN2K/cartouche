import Foundation

enum OverlaySection: String, CaseIterable, Identifiable, Sendable {
    case performance, upscaling, frameGeneration, resources, display, capture, controller, notes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .performance: ot("Performance")
        case .upscaling: ot("Upscaling")
        case .frameGeneration: ot("Generated Frames")
        case .resources: ot("Mac Resources")
        case .display: ot("Display")
        case .capture: ot("Capture")
        case .controller: ot("Controller")
        case .notes: ot("Notes")
        }
    }

    var short: String {
        switch self {
        case .performance: ot("Perf.")
        case .upscaling: ot("Scaling")
        case .frameGeneration: ot("Frames")
        case .resources: ot("Resources")
        default: title
        }
    }

    var symbol: String {
        switch self {
        case .performance: "gauge.with.dots.needle.33percent"
        case .upscaling: "arrow.up.left.and.arrow.down.right"
        case .frameGeneration: "square.on.square"
        case .resources: "cpu"
        case .display: "rectangle.topthird.inset.filled"
        case .capture: "camera"
        case .controller: "gamecontroller"
        case .notes: "doc.text"
        }
    }

    // What an anti-cheat leaves: Performance and Affichage lose some rows, two tabs lose everything
    var lockedByAntiCheat: Bool { self == .upscaling || self == .frameGeneration }

    var feature: OverlayFeature? {
        switch self {
        case .frameGeneration: .frameGeneration
        case .capture: .capture
        case .controller: .controller
        default: nil
        }
    }
}

// A feature that is not ready stays visible as « Bientôt »
enum OverlayFeature: String, CaseIterable, Sendable {
    case frameGeneration, capture, controller

    static let defaultsPrefix = "overlay.soon."
    // Capture waits for the replay engine
    static let soonByDefault: Set<OverlayFeature> = [.frameGeneration, .capture]

    var teaser: String {
        switch self {
        case .frameGeneration: ot("Up to twice as many frames shown.")
        case .capture: ot("Record your games without leaving them.")
        case .controller: ot("Tune the controller for each game.")
        }
    }

    // Read once when the overlay starts
    static func soon(_ defaults: UserDefaults = .standard) -> Set<OverlayFeature> {
        Set(allCases.filter { feature in
            let key = defaultsPrefix + feature.rawValue
            return defaults.object(forKey: key) == nil ? soonByDefault.contains(feature) : defaults.bool(forKey: key)
        })
    }
}

enum UpscaleMode: Int, Codable, CaseIterable, Sendable { case off, spatial, temporal }
enum FrameGenMode: Int, Codable, CaseIterable, Sendable { case off, x2, x4 }
enum FrameCap: Int, Codable, CaseIterable, Sendable {
    case fps30, fps40, fps60, none
    var fps: Double? { [30, 40, 60, nil][rawValue] }
}
enum HUDLevel: Int, Codable, CaseIterable, Sendable { case hidden, mini, standard, full }
enum HUDCorner: Int, Codable, CaseIterable, Sendable { case topLeft, topRight, bottomLeft, bottomRight }

// The per-game profile: every setting the menu changes
struct OverlaySettings: Codable, Equatable, Sendable {
    var upscale = UpscaleMode.temporal
    var renderScale = 67
    var sharpness = 30
    var antialiasing = true
    var frameGen = FrameGenMode.x2
    var frameCap = FrameCap.fps60
    var frameGenOnGPU = false
    var protectInterface = true
    var hud = HUDLevel.hidden
    var corner = HUDCorner.topLeft
    var hudSize = 0
    var hideMetalHUD = true
    var replay = false
    var captureHUD = false
    var padLayout = 0
    var swapAB = false
    var threshold = 70
    var resumeApps = true
    // Cartouche Sharpening, our code in the game; nil follows the game: on, off under an anti-cheat
    var sharpening: Bool?

    func allowsOurCode(protected: Bool) -> Bool { sharpening ?? !protected }

    // A game without DLSS has no temporal mode
    func fitted(dlss: Bool) -> OverlaySettings {
        var out = self
        if !dlss && out.upscale == .temporal { out.upscale = .spatial }
        out.renderScale = min(100, max(50, out.renderScale))
        out.sharpness = min(100, max(0, out.sharpness))
        out.threshold = min(95, max(30, out.threshold))
        out.hudSize = min(2, max(0, out.hudSize))
        out.padLayout = min(2, max(0, out.padLayout))
        return out
    }
}

extension OverlaySettings {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = OverlaySettings()
        upscale = (try? c.decode(UpscaleMode.self, forKey: .upscale)) ?? d.upscale
        renderScale = (try? c.decode(Int.self, forKey: .renderScale)) ?? d.renderScale
        sharpness = (try? c.decode(Int.self, forKey: .sharpness)) ?? d.sharpness
        antialiasing = (try? c.decode(Bool.self, forKey: .antialiasing)) ?? d.antialiasing
        frameGen = (try? c.decode(FrameGenMode.self, forKey: .frameGen)) ?? d.frameGen
        frameCap = (try? c.decode(FrameCap.self, forKey: .frameCap)) ?? d.frameCap
        frameGenOnGPU = (try? c.decode(Bool.self, forKey: .frameGenOnGPU)) ?? d.frameGenOnGPU
        protectInterface = (try? c.decode(Bool.self, forKey: .protectInterface)) ?? d.protectInterface
        hud = (try? c.decode(HUDLevel.self, forKey: .hud)) ?? d.hud
        corner = (try? c.decode(HUDCorner.self, forKey: .corner)) ?? d.corner
        hudSize = (try? c.decode(Int.self, forKey: .hudSize)) ?? d.hudSize
        hideMetalHUD = (try? c.decode(Bool.self, forKey: .hideMetalHUD)) ?? d.hideMetalHUD
        replay = (try? c.decode(Bool.self, forKey: .replay)) ?? d.replay
        captureHUD = (try? c.decode(Bool.self, forKey: .captureHUD)) ?? d.captureHUD
        padLayout = (try? c.decode(Int.self, forKey: .padLayout)) ?? d.padLayout
        swapAB = (try? c.decode(Bool.self, forKey: .swapAB)) ?? d.swapAB
        threshold = (try? c.decode(Int.self, forKey: .threshold)) ?? d.threshold
        resumeApps = (try? c.decode(Bool.self, forKey: .resumeApps)) ?? d.resumeApps
        sharpening = (try? c.decodeIfPresent(Bool.self, forKey: .sharpening)) ?? nil
    }
}

// Off and the layer's own DLSS → MetalFX run without consent; Spatial, our chain and the in-game HUD
// need Cartouche Sharpening
struct UpscaleAccess: Equatable, Sendable {
    // The game ships DLSS and the layer hands it to MetalFX
    var dlss: Bool
    var sharpening: Bool

    func effective(_ mode: UpscaleMode) -> UpscaleMode {
        switch mode {
        case .off: .off
        case .temporal where dlss: .temporal
        default: sharpening ? .spatial : .off
        }
    }

    func allows(_ mode: UpscaleMode) -> Bool { effective(mode) == mode }

    // Render scale and sharpness are our chain's; the layer's DLSS leaves them to the game
    func scales(_ mode: UpscaleMode) -> Bool { sharpening && effective(mode) != .off }
}

// The game the menu is about
struct OverlayGame: Equatable, Sendable {
    var id: String
    var name: String
    var pid: pid_t
    // The game ships DLSS and its layer hands it to MetalFX
    var dlss = false
    // The anti-cheat's name when the game has one
    var antiCheat: String?
    // The launch really wrote CARTOUCHE_FRAMEGEN=1, so the library is in the game
    var libraryLoaded = false

    var isProtected: Bool { antiCheat != nil }
}

// The launch variables a profile adds; protected: our code stays out, none of the library's
enum OverlayLaunch {
    static let hudVariable = "CARTOUCHE_OVERLAY"
    static let cornerVariable = "CARTOUCHE_OVERLAY_POS"
    // Keeps a HUD that starts hidden ready to be shown live from the menu
    static let controlVariable = "CARTOUCHE_OVERLAY_CONTROL"
    // The HUD's labels follow the app's language
    static let languageVariable = "CARTOUCHE_OVERLAY_LANG"
    static let variables: Set<String> = [hudVariable, cornerVariable, controlVariable, languageVariable, FrameGeneration.variable,
                                         FrameGeneration.temporalVariable, FrameGeneration.statsVariable, FrameGeneration.interpolateVariable]

    // supported: the game's options; our library works on the Metal backends, the ones with the Metal HUD
    static func environment(_ settings: OverlaySettings, supported: Set<AdvancedOption>, protected: Bool,
                            existing: [String: String]) -> [String: String] {
        var env = existing
        guard !protected else {
            for key in variables {
                env.removeValue(forKey: key)
            }
            return env
        }
        env[hudVariable] = ["off", "mini", "std", "full"][settings.hud.rawValue]
        env[cornerVariable] = ["tl", "tr", "bl", "br"][settings.corner.rawValue]
        env[controlVariable] = "1"
        env[languageVariable] = OverlayText.language
        if settings.hideMetalHUD { env["MTL_HUD_ENABLED"] = "0" }
        // Our DLSS chain is the temporal mode; anything else turns it off for this game
        let temporal = settings.fitted(dlss: supported.contains(.dlss)).upscale == .temporal
        if temporal { env.removeValue(forKey: FrameGeneration.temporalVariable) }
        else { env[FrameGeneration.temporalVariable] = "off" }
        // The library loads only for what the profile asks of it: the temporal chain or the HUD
        if supported.contains(.metalHUD) && (temporal || settings.hud != .hidden) { env[FrameGeneration.variable] = "1" }
        else { env.removeValue(forKey: FrameGeneration.variable) }
        return env
    }
}
