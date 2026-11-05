import Foundation

// The page's Advanced switches before 0.2.0 now live in the game's profile, the one the in-game menu edits
enum GameProfile {
    static func hasLegacy(_ choice: GameSetupChoice) -> Bool {
        choice.metalHUD != nil || choice.advanced.map { $0.dlss || $0.spatial || $0.spatialFactor != 2 } == true
    }

    // A first migration reads an Advanced record as it played: no DLSS and no MetalFX means no upscaling
    static func migrated(_ choice: GameSetupChoice, onto base: OverlaySettings = OverlaySettings(), first: Bool) -> OverlaySettings {
        var s = base
        if let a = choice.advanced, first || a.dlss || a.spatial {
            s.upscale = a.dlss ? .temporal : a.spatial ? .spatial : .off
            if a.spatial { s.renderScale = renderScale(factor: a.spatialFactor) }
        }
        if let hud = choice.metalHUD { s.hideMetalHUD = !hud }
        return s
    }

    static func cleared(_ choice: GameSetupChoice) -> GameSetupChoice {
        var c = choice
        c.metalHUD = nil
        if var a = c.advanced {
            a.dlss = false
            a.spatial = false
            a.spatialFactor = 2
            c.advanced = a == AdvancedGameOptions() ? nil : a
        }
        return c
    }

    // MetalFX's spatial factor is the render scale's inverse: 67 % renders 1/1.49 of the output
    static func renderScale(factor: Double) -> Int {
        guard factor.isFinite, factor > 0 else { return OverlaySettings().renderScale }
        return min(100, max(50, Int((100 / factor).rounded())))
    }

    static func factor(renderScale: Int) -> Double {
        let scale = Double(min(100, max(50, renderScale)))
        return ((100 / scale) * 100).rounded() / 100
    }
}

// What a launch reads from the profile; under an anti-cheat, only Off and the layer's DLSS without consent
struct LaunchProfile: Equatable, Sendable {
    var settings: OverlaySettings
    var protected = false
    // The game ships DLSS. Without it D3DM_ENABLE_METALFX is never set: it cut Deadlock's FPS by 2.7
    var dlss = false

    var sharpening: Bool { settings.allowsOurCode(protected: protected) }

    static let consentVariable = "CARTOUCHE_SHARPENING"
    static let metalFXVariable = "D3DM_ENABLE_METALFX"

    // The launch's last word on MetalFX: whatever carried the flag — a kept variable, a migration's
    // fallback, a store adapter's environment — without the game's own DLSS it never reaches a launch.
    static func filteredEnvironment(_ environment: [String: String], dlss: Bool) -> [String: String] {
        dlss ? environment : environment.filter { $0.key != metalFXVariable }
    }

    func access(layerDLSS: Bool) -> UpscaleAccess { UpscaleAccess(dlss: dlss && layerDLSS, sharpening: sharpening) }

    func advanced(_ choice: AdvancedGameOptions?, layerDLSS: Bool) -> AdvancedGameOptions {
        var a = choice ?? AdvancedGameOptions()
        let mode = access(layerDLSS: layerDLSS).effective(settings.upscale)
        a.dlss = mode == .temporal
        a.spatial = mode == .spatial
        a.spatialFactor = GameProfile.factor(renderScale: settings.fitted(dlss: false).renderScale)
        return a
    }
}

// A game ships DLSS when its folder holds NVIDIA's DLSS library
enum GameDLSS {
    static let files: Set<String> = ["nvngx_dlss.dll", "sl.dlss.dll"]

    static func ships(in folder: URL, depth: Int = 8, limit: Int = 60_000) -> Bool {
        GameDiskScan.scan(in: folder, depth: depth, limit: limit).dlss
    }
}

// The filenames that tell a game ships an anti-cheat; the launch scans for them like the compat base does
enum GameAntiCheat {
    static let marks = ["EasyAntiCheat", "EasyAntiCheat_EOS.dll", "EasyAntiCheat_x64.dll", "BEService.exe",
                        "BEClient_x64.dll", "BattlEye", "mhypbase.dll", "vgc.exe"]

    static func name(ofMark mark: String) -> String {
        let m = mark.lowercased()
        return m.hasPrefix("be") || m == "battleye" ? "BattlEye" : m.hasPrefix("easy") ? "Easy Anti-Cheat" : mark
    }
}

// One folder walk answers both questions a launch asks of the game's files
struct GameDiskScan: Equatable, Sendable {
    var dlss = false
    var antiCheat: String? = nil
    // Stays false until the walk saw the whole folder: an incomplete walk never means "no anti-cheat".
    // Pruning past depth 8 still counts as complete: the marks ship at the surface.
    var complete = false
    // The folder's stamp read just before the walk; Play compares a fresh read before trusting the cache
    var stamp: String? = nil

    static func scan(in folder: URL, depth: Int = 8, limit: Int = 60_000) -> GameDiskScan {
        var out = GameDiskScan()
        var failed = false
        guard let walk = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil,
                                                        options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                                        errorHandler: { _, _ in failed = true; return true })
        else { return out }
        let marks = Set(GameAntiCheat.marks.map { $0.lowercased() })
        var seen = 0
        for case let url as URL in walk {
            seen += 1
            if seen > limit { return out }
            if walk.level > depth { walk.skipDescendants(); continue }
            let name = url.lastPathComponent.lowercased()
            if GameDLSS.files.contains(name) { out.dlss = true }
            if out.antiCheat == nil, marks.contains(name) {
                out.antiCheat = GameAntiCheat.name(ofMark: url.lastPathComponent)
            }
            if out.dlss, out.antiCheat != nil { break }
        }
        out.complete = !failed
        return out
    }

    // What Play re-reads before trusting a cached walk — a few stats, never a re-walk: for a Steam
    // game the manifest's build keys, plus the folder's own and its first-level entries' dates.
    static func stamp(appID: Int?, of folder: URL) -> String {
        var parts: [String] = []
        if let appID, folder.deletingLastPathComponent().lastPathComponent == "common" {
            let manifest = folder.deletingLastPathComponent().deletingLastPathComponent()
                .appending(path: "appmanifest_\(appID).acf")
            let state = VDF.read(manifest)?["AppState"]
            parts.append("s\(state?["buildid"]?.string ?? "")#\(state?["LastUpdated"]?.string ?? "")")
        }
        let fm = FileManager.default, path = folder.path(percentEncoded: false)
        parts.append("\(((try? fm.attributesOfItem(atPath: path)[.modificationDate]) as? Date)?.timeIntervalSince1970 ?? 0)")
        for name in ((try? fm.contentsOfDirectory(atPath: path)) ?? []).sorted() {
            let item = folder.appending(path: name).path(percentEncoded: false)
            let date = (try? fm.attributesOfItem(atPath: item)[.modificationDate]) as? Date
            parts.append("\(name)=\(date?.timeIntervalSince1970 ?? 0)")
        }
        return parts.joined(separator: "|")
    }
}
