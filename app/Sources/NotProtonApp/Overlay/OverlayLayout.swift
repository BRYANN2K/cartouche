import Foundation

// Everything a section's content depends on
struct OverlayContext: Equatable, Sendable {
    var game: OverlayGame
    var settings = OverlaySettings()
    var soon = OverlayFeature.soonByDefault
    var live = OverlayLive()
    // The Resources manager's alert threshold, percent of the whole Mac's CPU
    var threshold = 70
    var macOpen = false
    var armedApp: pid_t?
    var hotkey = "⌥C"
    var hudHotkey = "⌥⇧C"
    var replayAvailable = false

    func isSoon(_ section: OverlaySection) -> Bool { section.feature.map(soon.contains) ?? false }

    var access: UpscaleAccess { UpscaleAccess(dlss: game.dlss, sharpening: settings.allowsOurCode(protected: game.isProtected)) }

    // Our code stays out of the game: an anti-cheat without consent, or Cartouche Sharpening turned off
    var restricted: Bool { !access.sharpening }

    // « Bientôt » first: a feature that does not exist yet is not locked either. Upscaling keeps the layer's DLSS
    func isLocked(_ section: OverlaySection) -> Bool {
        guard restricted, section.lockedByAntiCheat, !isSoon(section) else { return false }
        return section != .upscaling || !game.dlss
    }

    var upscaleOptions: [String] {
        game.dlss ? [ot("Off"), ot("Cartouche"), ot("DLSS")] : [ot("Off"), ot("Cartouche")]
    }

    // The mode segment: Off and DLSS only while our code stays out
    var upscaleControl: OverlayControl {
        restricted ? .segment([ot("Off"), ot("DLSS")], .upscaleBase) : .segment(upscaleOptions, .upscale)
    }

    // FPS are known from the library, or from outside the game with Screen Recording
    var framesKnown: Bool { live.metrics != nil }
}

enum OverlayLayout {
    static var lockReason: String { ot("Turn on Cartouche Engine on the game's page") }

    static func blocks(_ section: OverlaySection, _ c: OverlayContext) -> [OverlayBlock] {
        if c.isSoon(section) { return [.soon(section)] }
        if c.isLocked(section) {
            return [.empty(symbol: "lock", title: lockReason, action: nil),
                    .group(heading: nil, rows: [OverlayRow(id: .heavyApps, title: ot("Heavy Apps"),
                                                           control: .button(ot("See"), prominent: false))])]
        }
        switch section {
        case .performance: return performance(c)
        case .upscaling: return upscaling(c)
        case .frameGeneration: return frameGeneration(c)
        case .resources: return resources(c)
        case .display: return display(c)
        case .capture: return capture(c)
        case .controller: return controller(c)
        case .notes: return [.notes]
        }
    }

    // The rows keyboard and controller focus moves through, in order
    static func rows(_ section: OverlaySection, _ c: OverlayContext) -> [OverlayRow] {
        blocks(section, c).flatMap(\.rows)
    }

    // MARK: Performance

    static func performance(_ c: OverlayContext) -> [OverlayBlock] {
        var blocks: [OverlayBlock] = [.stats]
        if c.restricted && !c.live.captureAllowed {
            blocks.append(.group(heading: nil, rows: [OverlayRow(
                id: .measure, title: ot("Measure FPS"), control: .button(ot("Allow…"), prominent: true),
                tip: ot("Asks for the Screen Recording permission"))]))
        }
        blocks.append(.group(heading: nil, rows: [verdict(c)]))
        let s = c.settings
        var quick: [OverlayRow] = []
        var up = OverlayRow(id: .perfUpscale, title: ot("Upscaling"),
                            detail: c.access.scales(s.upscale) ? String(format: ot("Rendered at %@"), OverlayFormat.percent(Double(s.renderScale))) : nil,
                            control: c.upscaleControl)
        if c.isLocked(.upscaling) { up.state = .locked(lockReason) }
        quick.append(up)
        if c.soon.contains(.frameGeneration) {
            quick.append(OverlayRow(id: .perfFrameGen, title: ot("Generated Frames"), control: .soon))
        } else {
            var fg = OverlayRow(id: .perfFrameGen, title: ot("Generated Frames"),
                                detail: s.frameGen == .off ? nil : String(format: ot("+%@ latency"), OverlayFormat.unit(s.frameGen == .x2 ? "6" : "9", "ms")),
                                control: .segment([ot("Off"), "×2", "×4"], .frameGen))
            if c.restricted { fg.state = .locked(lockReason) }
            quick.append(fg)
        }
        var cap = OverlayRow(id: .perfCap, title: ot("Real Frame Limit"), control: .segment(capOptions, .frameCap))
        if c.restricted { cap.state = .locked(ot("Set the limit in the game's options")) }
        quick.append(cap)
        quick.append(OverlayRow(id: .power, title: ot("Low Power Mode"), detail: c.live.mac.lowPower ? ot("Turned On") : ot("Turned Off"),
                                control: .button(ot("Open Settings…"), prominent: false)))
        blocks.append(.group(heading: nil, rows: quick))
        blocks.append(.fold(OverlayRow(id: .macFold, title: ot("Your Mac"), control: .fold(open: c.macOpen))))
        if c.macOpen { blocks.append(.mac) }
        return blocks
    }

    static var capOptions: [String] { ["30", "40", "60", ot("None")] }

    static func verdict(_ c: OverlayContext) -> OverlayRow {
        let live = c.live
        guard let m = live.metrics else { return OverlayRow(id: .verdict, title: ot("Waiting for the game"), control: .none) }
        let gpu = m.gpuPercent ?? live.mac.gameGPUPercent ?? live.mac.gpuPercent ?? 0
        if c.restricted {
            if gpu >= 95 {
                return OverlayRow(id: .verdict, title: String(format: ot("GPU very busy (%@)"), OverlayFormat.percent(gpu)),
                                  control: .none, tip: ot("Lower the quality in the game's options"))
            }
            return OverlayRow(id: .verdict, title: ot("No problem"), control: .none)
        }
        if live.othersCPU > Double(c.threshold), let top = live.top {
            return OverlayRow(id: .verdict, title: ot("Other apps slow the game down"),
                              detail: String(format: ot("%1$@: %2$@ of the CPU"), top.name, OverlayFormat.percent(top.cpu)),
                              control: .button(ot("See Apps"), prominent: true))
        }
        if let fps = c.settings.frameCap.fps, let real = m.realFPS, real >= fps - 1.5 {
            return OverlayRow(id: .verdict, title: String(format: ot("Capped at %@ real frames"), OverlayFormat.whole(fps)), control: .none)
        }
        if gpu >= 95 {
            if c.settings.upscale == .off {
                let kind = c.game.dlss ? ot("temporal kind") : ot("spatial kind")
                return OverlayRow(id: .verdict, title: ot("The GPU limits the game"),
                                  detail: String(format: ot("%1$@ upscaling at %2$@"), kind, OverlayFormat.percent(67)),
                                  control: .button(ot("Turn On"), prominent: true))
            }
            if c.settings.renderScale > 58 {
                return OverlayRow(id: .verdict, title: String(format: ot("The GPU limits the game (%@)"), OverlayFormat.percent(gpu)),
                                  control: .button(String(format: ot("Set to %@"), OverlayFormat.percent(58)), prominent: true))
            }
        }
        return OverlayRow(id: .verdict, title: ot("No problem"), control: .none)
    }

    // MARK: Upscaling, generated frames

    static func upscaling(_ c: OverlayContext) -> [OverlayBlock] {
        let s = c.settings
        let mode = c.access.effective(s.upscale)
        let off = mode == .off
        let first = c.restricted ? ot("Choose DLSS first") : ot("Choose Cartouche or DLSS first")
        let size = c.live.metrics?.upscaleOut ?? .zero
        let scaled = size == .zero ? nil : String(format: "%d × %d", Int(size.width * CGFloat(s.renderScale) / 100),
                                                  Int(size.height * CGFloat(s.renderScale) / 100))
        var scale = OverlayRow(id: .upScale, title: ot("Render Scale"), detail: c.access.scales(s.upscale) ? scaled : nil,
                               control: .slider(.renderScale, min: 50, max: 100, step: 1, .percent))
        var sharp = OverlayRow(id: .upSharpness, title: ot("Sharpness"),
                               control: .slider(.sharpness, min: 0, max: 100, step: 5, .hundredths))
        var aa = OverlayRow(id: .upAntialias, title: ot("Anti-aliasing"), control: .toggle(.antialiasing))
        if !c.access.scales(s.upscale) {
            scale.state = .disabled(off ? first : lockReason)
            sharp.state = .disabled(off ? first : lockReason)
        }
        if mode != .spatial { aa.state = .disabled(c.restricted ? lockReason : ot("Choose Cartouche to turn it on")) }
        return [.group(heading: nil, rows: [
            OverlayRow(id: .upMode, title: ot("Mode"), control: c.upscaleControl), scale, sharp, aa,
        ])]
    }

    static func frameGeneration(_ c: OverlayContext) -> [OverlayBlock] {
        let s = c.settings
        let off = s.frameGen == .off
        let first = ot("Choose ×2 or ×4 first")
        let factor = s.frameGen == .x4 ? 4.0 : 2.0
        let shown = s.frameCap.fps.map { String(format: ot("%@ shown"), OverlayFormat.whole(min(120, $0 * factor))) }
            ?? ot("Up to 120 shown")
        var cap = OverlayRow(id: .fgCap, title: ot("Real Frame Limit"), detail: off ? nil : shown,
                             control: .segment(capOptions, .frameCap))
        var engine = OverlayRow(id: .fgEngine, title: ot("Compute"), control: .segment([ot("Neural Engine"), "GPU"], .engine))
        var protect = OverlayRow(id: .fgProtect, title: ot("Protect the Game's Interface"), control: .toggle(.protect))
        if off {
            cap.state = .disabled(first)
            engine.state = .disabled(first)
            protect.state = .disabled(first)
        }
        var blocks: [OverlayBlock] = [.group(heading: nil, rows: [
            OverlayRow(id: .fgMode, title: ot("Mode"), control: .segment([ot("Off"), "×2", "×4"], .frameGen)), cap, engine, protect,
        ])]
        if s.frameGen == .x4, let real = c.live.metrics?.realFPS, real < 40 {
            blocks.append(.warning(ot("Under 40 real frames, ×4 leaves trails.")))
        }
        return blocks
    }

    // MARK: Resources

    // Paused apps stay listed; the others show from 2 % of CPU or GPU
    static func heavy(_ apps: [OverlayApp]) -> [OverlayApp] {
        apps.filter { $0.paused || $0.cpu >= 2 || $0.gpu >= 2 }
    }

    static func resources(_ c: OverlayContext) -> [OverlayBlock] {
        let apps = heavy(c.live.apps)
        let list: OverlayBlock = apps.isEmpty
            ? .empty(symbol: "checkmark", title: ot("No Heavy Apps"), action: nil)
            : .group(heading: ot("Apps"), rows: apps.map { OverlayRow(id: .app($0.pid), title: $0.name, control: .app) })
        return [.loadAlert, list, .group(heading: nil, rows: [
            OverlayRow(id: .threshold, title: ot("Alert Threshold"), control: .threshold(c.threshold)),
            OverlayRow(id: .resumeApps, title: ot("Resume Apps After the Game"), control: .toggle(.resumeApps)),
        ])]
    }

    // MARK: Display, capture, controller

    static func display(_ c: OverlayContext) -> [OverlayBlock] {
        var rows = [
            OverlayRow(id: .hudLevel, title: "HUD", control: .segment([ot("Hidden"), "Mini", "Standard", ot("Full")], .hud)),
            OverlayRow(id: .hudCorner, title: ot("Position"), control: .corners),
            OverlayRow(id: .hudSize, title: ot("HUD Size"),
                       control: .segment([100, 125, 150].map { OverlayFormat.percent(Double($0)) }, .hudSize)),
        ]
        if !c.restricted {
            rows.append(OverlayRow(id: .hideMetalHUD, title: ot("Hide Apple's Metal HUD"), control: .toggle(.hideMetalHUD), later: true))
        }
        rows.append(OverlayRow(id: .shortcuts, title: ot("Shortcuts"),
                               detail: String(format: ot("%1$@ menu · %2$@ HUD"), c.hotkey, c.hudHotkey),
                               control: .button(ot("Edit…"), prominent: false)))
        return [.group(heading: nil, rows: rows)]
    }

    static func capture(_ c: OverlayContext) -> [OverlayBlock] {
        guard c.live.captureAllowed else {
            return [.empty(symbol: "camera", title: ot("Screen Recording Not Allowed"),
                           action: OverlayRow(id: .allowCapture, title: "", control: .button(ot("Allow…"), prominent: true)))]
        }
        var replay = OverlayRow(id: .replay, title: ot("Keep the Last 30 Seconds"), control: .toggle(.replay))
        var clip = OverlayRow(id: .clip, title: ot("Clip"), detail: "⌥F6", control: .button(ot("Save Clip"), prominent: false))
        if !c.replayAvailable {
            replay.state = .disabled(ot("Coming Soon"))
            clip.state = .disabled(ot("Coming Soon"))
        } else if !c.settings.replay {
            clip.state = .disabled(ot("Turn on « Keep the Last 30 Seconds »"))
        }
        return [.group(heading: nil, rows: [
            OverlayRow(id: .screenshot, title: ot("Screenshot"), detail: "⌥F5", control: .button(ot("Take"), prominent: false)),
            replay, clip,
            OverlayRow(id: .captureHUD, title: ot("Include the HUD"), control: .toggle(.captureHUD)),
        ])]
    }

    static func controller(_ c: OverlayContext) -> [OverlayBlock] {
        guard let pad = c.live.controller else {
            return [.empty(symbol: "gamecontroller", title: ot("No Controller Connected"), action: nil)]
        }
        let battery = pad.battery.map { String(format: ot("Battery %@"), OverlayFormat.percent($0 * 100)) }
        return [.group(heading: nil, rows: [
            OverlayRow(id: .pad, title: pad.shortName, detail: battery, control: .button(ot("Rumble"), prominent: false)),
            OverlayRow(id: .padLayout, title: ot("Controller Type"), control: .segment(["Xbox", "PlayStation", "Nintendo"], .padLayout), later: true),
            OverlayRow(id: .swapAB, title: ot("Swap A and B"), control: .toggle(.swapAB), later: true),
        ])]
    }
}
