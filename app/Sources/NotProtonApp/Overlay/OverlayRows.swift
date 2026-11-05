import Foundation

// One setting of the profile seen as a small integer, so segments, switches, sliders and the
// keyboard share one path
enum SettingKey: Sendable, Hashable {
    case upscale, renderScale, sharpness, antialiasing, frameGen, frameCap, engine, protect
    // Off or DLSS, all a game gets without Cartouche Sharpening
    case upscaleBase
    case hud, corner, hudSize, hideMetalHUD, replay, captureHUD, padLayout, swapAB, resumeApps

    func get(_ s: OverlaySettings) -> Int {
        switch self {
        case .upscale: s.upscale.rawValue
        case .upscaleBase: s.upscale == .temporal ? 1 : 0
        case .renderScale: s.renderScale
        case .sharpness: s.sharpness
        case .antialiasing: s.antialiasing ? 1 : 0
        case .frameGen: s.frameGen.rawValue
        case .frameCap: s.frameCap.rawValue
        case .engine: s.frameGenOnGPU ? 1 : 0
        case .protect: s.protectInterface ? 1 : 0
        case .hud: s.hud.rawValue
        case .corner: s.corner.rawValue
        case .hudSize: s.hudSize
        case .hideMetalHUD: s.hideMetalHUD ? 1 : 0
        case .replay: s.replay ? 1 : 0
        case .captureHUD: s.captureHUD ? 1 : 0
        case .padLayout: s.padLayout
        case .swapAB: s.swapAB ? 1 : 0
        case .resumeApps: s.resumeApps ? 1 : 0
        }
    }

    func set(_ s: inout OverlaySettings, _ v: Int) {
        switch self {
        case .upscale: s.upscale = UpscaleMode(rawValue: v) ?? s.upscale
        case .upscaleBase: s.upscale = v == 0 ? .off : .temporal
        case .renderScale: s.renderScale = v
        case .sharpness: s.sharpness = v
        case .antialiasing: s.antialiasing = v != 0
        case .frameGen: s.frameGen = FrameGenMode(rawValue: v) ?? s.frameGen
        case .frameCap: s.frameCap = FrameCap(rawValue: v) ?? s.frameCap
        case .engine: s.frameGenOnGPU = v != 0
        case .protect: s.protectInterface = v != 0
        case .hud: s.hud = HUDLevel(rawValue: v) ?? s.hud
        case .corner: s.corner = HUDCorner(rawValue: v) ?? s.corner
        case .hudSize: s.hudSize = v
        case .hideMetalHUD: s.hideMetalHUD = v != 0
        case .replay: s.replay = v != 0
        case .captureHUD: s.captureHUD = v != 0
        case .padLayout: s.padLayout = v
        case .swapAB: s.swapAB = v != 0
        case .resumeApps: s.resumeApps = v != 0
        }
    }
}

enum OverlayRowID: Hashable, Sendable {
    case measure, verdict, perfUpscale, perfFrameGen, perfCap, power, macFold
    case upMode, upScale, upSharpness, upAntialias
    case fgMode, fgCap, fgEngine, fgProtect
    case app(pid_t), threshold, resumeApps
    case hudLevel, hudCorner, hudSize, hideMetalHUD, shortcuts
    case screenshot, replay, clip, captureHUD, allowCapture
    case pad, padLayout, swapAB
    case notes, heavyApps, soon
}

enum SliderFormat: Sendable, Equatable { case percent, hundredths, cpu }

enum OverlayControl: Equatable, Sendable {
    case none
    case segment([String], SettingKey)
    case toggle(SettingKey)
    case slider(SettingKey, min: Int, max: Int, step: Int, SliderFormat)
    // The threshold slider reads the Resources manager, not the profile
    case threshold(Int)
    case button(String, prominent: Bool)
    case corners
    case fold(open: Bool)
    case app
    case soon
    case notes
}

enum OverlayRowState: Equatable, Sendable {
    case normal
    // Greyed, value kept; the tip says what to do first
    case disabled(String)
    // A lock instead of the control, with the reason
    case locked(String)
}

struct OverlayRow: Identifiable, Equatable, Sendable {
    var id: OverlayRowID
    var title: String
    var detail: String?
    var control: OverlayControl
    var state = OverlayRowState.normal
    var tip: String?
    var later = false

    // The text the tooltip and the footer show: the lock reason, what to do first, or the row's own hint
    var help: String? {
        switch state {
        case .locked(let why): why
        case .disabled(let why): why
        case .normal: tip
        }
    }

    var isActionable: Bool {
        guard state == .normal else { return false }
        switch control {
        case .none, .soon, .notes: return false
        default: return true
        }
    }
}

// A group of rows as the window draws it: a heading, a plain group, or a block that is not a row
enum OverlayBlock: Equatable, Sendable {
    case stats
    case group(heading: String?, rows: [OverlayRow])
    case fold(OverlayRow)
    case mac
    case loadAlert
    case empty(symbol: String, title: String, action: OverlayRow?)
    case soon(OverlaySection)
    case warning(String)
    case notes

    var rows: [OverlayRow] {
        switch self {
        case .group(_, let rows): rows
        case .fold(let row): [row]
        case .empty(_, _, let action): action.map { [$0] } ?? []
        case .notes: [OverlayRow(id: .notes, title: "", control: .notes)]
        default: []
        }
    }
}
