import AppKit
import ScreenCaptureKit
import SwiftUI
import Testing
@testable import NotProtonApp

// Evidence PNGs of the real overlay views over a stand-in scene. Runs only with
// CARTOUCHE_OVERLAY_SNAPSHOTS=<folder>. The window is ours alone: on the built-in display,
// non-activating, ignoring the mouse, captured by itself (never the screen).
@MainActor
@Suite("Overlay snapshots", .serialized, .enabled(if: ProcessInfo.processInfo.environment["CARTOUCHE_OVERLAY_SNAPSHOTS"] != nil))
struct OverlaySnapshotTests {
    let folder = URL(filePath: ProcessInfo.processInfo.environment["CARTOUCHE_OVERLAY_SNAPSHOTS"] ?? "/tmp")

    init() { OverlayText.use(language: "fr") }

    static let apps = [
        OverlayApp(pid: 90001, name: "Google Chrome", cpu: 30, gpu: 6, memoryGB: 3.1),
        OverlayApp(pid: 90002, name: "Photos", cpu: 18, gpu: 15, memoryGB: 1.4),
        OverlayApp(pid: 90003, name: "Docker Desktop", cpu: 9, gpu: 0, memoryGB: 2.6),
        OverlayApp(pid: 90004, name: "Adobe Creative Cloud Desktop Experience Manager", cpu: 4, gpu: 1, memoryGB: 0.9),
        OverlayApp(pid: 90005, name: "Spotlight", cpu: 5, gpu: 0, memoryGB: 0.2, system: true),
    ]

    static func times() -> [Double] {
        (0..<120).map { (i: Int) -> Double in
            if i == 96 { return 34 }
            let wobble: Double = sin(Double(i) * 1.7) * 0.6
            return 16.9 + wobble
        }
    }

    func center(protected: Bool = false, soon: Set<OverlayFeature> = OverlayFeature.soonByDefault, dlss: Bool = true,
                section: OverlaySection = .performance, capture: Bool = true, metrics: Bool = true) -> OverlayCenter {
        let game = OverlayGame(id: "hollow-pines-\(UUID().uuidString)", name: "Hollow Pines", pid: 4242, dlss: dlss,
                               antiCheat: protected ? "Easy Anti-Cheat" : nil)
        let store = OverlayProfileStore(folder: FileManager.default.temporaryDirectory.appending(path: "overlay-snap-\(UUID().uuidString)"))
        let c = OverlayCenter(game: game, store: store, soon: soon)
        c.setOpen(true)
        c.threshold = 70
        c.live.sessionStart = Date().addingTimeInterval(-72 * 60)
        c.live.captureAllowed = capture
        c.live.mac = MacReadings(cpuPercent: 63, gpuPercent: 98, gameGPUPercent: 91, gpuWatts: 14.4, memoryBytes: 17_100_000_000,
                                 thermal: 1, battery: 82)
        c.live.apps = Self.apps
        c.live.othersCPU = 41
        c.live.controller = ControllerInfo(id: "1", name: "DualSense", shortName: "DualSense", family: .playStation, battery: 0.6)
        if metrics && (!protected || capture) {
            c.live.metrics = GameMetrics(presentedFPS: 59, realFPS: protected ? nil : 58, low1FPS: 51, frameMs: 16.9,
                                         latencyMs: protected ? nil : 25, gpuPercent: 99, thermal: 1,
                                         upscale: .temporal, upscaleOut: CGSize(width: 2560, height: 1440),
                                         external: protected, frameTimes: Self.times())
        }
        c.nav.go(section, by: .pointer)
        c.notes = "Code du coffre de la scierie : 4-1-7.\nNe pas vendre la lanterne bleue (quête du chapitre 3).\nRéglage qui marche : temporel 67 %, ×2, limite 60."
        return c
    }

    func shoot(_ name: String, _ c: OverlayCenter, size: CGSize = CGSize(width: 1600, height: 1000), sky: Bool = false,
               look: OverlayLook = OverlayLook(), hud: Bool = true, settle: Double = 0.6) async throws {
        let view = ZStack {
            StandInScene(sky: sky)
            OverlayView(center: c, shown: c.isOpen, nativeHUD: hud)
        }
        .environment(\.overlayLook, look)
        .environment(\.colorScheme, .dark)
        .frame(width: size.width, height: size.height)
        try await capture(view, size: size, to: folder.appending(path: "\(name).png"), settle: settle)
    }

    func capture<V: View>(_ view: V, size: CGSize, to url: URL, settle: Double) async throws {
        let screen = NSScreen.screens.first { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID).map { CGDisplayIsBuiltin($0) != 0 } ?? false
        }
        let builtin = try #require(screen, "no built-in display")
        let panel = OverlayPanel(screen: builtin, activating: false)
        panel.level = .normal
        panel.ignoresMouseEvents = true
        panel.setFrame(CGRect(origin: builtin.frame.origin, size: size), display: false)
        panel.contentView = NSHostingView(rootView: view)
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }
        try await Task.sleep(for: .seconds(settle))
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        let window = try #require(content.windows.first { $0.windowID == CGWindowID(panel.windowNumber) })
        let config = SCStreamConfiguration()
        config.width = Int(size.width * builtin.backingScaleFactor)
        config.height = Int(size.height * builtin.backingScaleFactor)
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window),
                                                               configuration: config)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let rep = NSBitmapImageRep(cgImage: image)
        try #require(rep.representation(using: .png, properties: [:])).write(to: url)
    }

    @Test func menus() async throws {
        try await shoot("menu-performance", center())
        try await shoot("menu-performance-sky", center(), sky: true)
        let open = center()
        open.macOpen = true
        try await shoot("menu-mac-open", open)
        try await shoot("menu-1280", center(), size: CGSize(width: 1280, height: 800))
        try await shoot("menu-upscaling", center(section: .upscaling))
        try await shoot("menu-upscaling-nodlss", center(dlss: false, section: .upscaling))
        try await shoot("menu-fg-soon", center(section: .frameGeneration))
        let off = center(soon: [], section: .frameGeneration)
        off.set(.frameGen, 0)
        try await shoot("menu-fg-off", off)
        try await shoot("menu-fg", center(soon: [], section: .frameGeneration))
        let busy = center(section: .resources)
        busy.live.othersCPU = 78
        busy.appAction(90002, sub: 0)
        busy.nav.armedApp = 90001
        try await shoot("menu-resources", busy)
        let empty = center(section: .resources)
        empty.live.apps = []
        empty.live.othersCPU = 6
        try await shoot("menu-resources-empty", empty)
        try await shoot("menu-display", center(section: .display))
        try await shoot("menu-capture-soon", center(section: .capture))
        try await shoot("menu-controller", center(section: .controller))
        let nopad = center(section: .controller)
        nopad.live.controller = nil
        try await shoot("menu-controller-none", nopad)
        try await shoot("menu-notes", center(section: .notes))
        let dirty = center()
        dirty.set(.frameCap, 1)
        try await shoot("menu-dirty", dirty)
        try await shoot("menu-stale", center(metrics: false))
    }

    @Test func antiCheat() async throws {
        try await shoot("menu-anticheat", center(protected: true))
        try await shoot("menu-anticheat-noperm", center(protected: true, capture: false))
        try await shoot("menu-anticheat-locked", center(protected: true, soon: [], section: .upscaling))
        try await shoot("menu-anticheat-fg-soon", center(protected: true, section: .frameGeneration))
        let closed = center(protected: true)
        closed.setOpen(false)
        try await shoot("hud-anticheat", closed)
    }

    @Test func accessibility() async throws {
        let keys = center()
        _ = keys.handle(.down, by: .keyboard)
        _ = keys.handle(.down, by: .keyboard)
        _ = keys.handle(.down, by: .keyboard)
        try await shoot("menu-keyboard", keys)
        try await shoot("menu-opaque", center(), look: OverlayLook(reduceTransparency: true))
        try await shoot("menu-contrast", center(section: .upscaling), sky: true, look: OverlayLook(contrast: true))
        try await shoot("menu-reduce-motion", center(), look: OverlayLook(reduceMotion: true))
    }

    @Test func english() async throws {
        OverlayText.use(language: "en")
        defer { OverlayText.use(language: "fr") }
        let en = "en/"
        try await shoot(en + "menu-performance", center())
        try await shoot(en + "menu-1280", center(), size: CGSize(width: 1280, height: 800))
        try await shoot(en + "menu-narrow-1100", center(section: .resources), size: CGSize(width: 1100, height: 760))
        try await shoot(en + "menu-upscaling", center(section: .upscaling))
        try await shoot(en + "menu-fg", center(soon: [], section: .frameGeneration))
        let busy = center(section: .resources)
        busy.live.othersCPU = 78
        busy.appAction(90002, sub: 0)
        try await shoot(en + "menu-resources", busy)
        try await shoot(en + "menu-display", center(section: .display))
        try await shoot(en + "menu-capture-soon", center(section: .capture))
        try await shoot(en + "menu-controller", center(section: .controller))
        try await shoot(en + "menu-notes", center(section: .notes))
        try await shoot(en + "menu-anticheat", center(protected: true))
        try await shoot(en + "menu-anticheat-noperm", center(protected: true, capture: false))
        try await shoot(en + "menu-anticheat-locked", center(protected: true, soon: [], section: .upscaling))
        let keys = center()
        _ = keys.handle(.down, by: .keyboard)
        try await shoot(en + "menu-keyboard", keys)
    }

    @Test func hudLevels() async throws {
        let c = center(protected: true)
        c.setOpen(false)
        for (i, level) in [HUDLevel.mini, .standard, .full].enumerated() {
            c.set(.hud, level.rawValue)
            try await shoot("hud-native-\(i + 1)-\(["mini", "standard", "full"][i])", c, size: CGSize(width: 600, height: 420), settle: 0.8)
        }
    }

    // The What's New HUD page, in each language, for a game without anti-cheat
    @Test func hudWhatsNew() async throws {
        defer { OverlayText.use(language: "fr") }
        for language in ["fr", "en"] {
            OverlayText.use(language: language)
            let c = center()
            c.setOpen(false)
            c.set(.hud, HUDLevel.standard.rawValue)
            try await shoot("whats-new-hud-\(language)", c, size: CGSize(width: 600, height: 420), settle: 0.8)
        }
    }
}

// The mockup's dusk and clear-sky road, drawn for the snapshots
struct StandInScene: View {
    var sky = false

    var body: some View {
        Canvas { ctx, size in
            let k = max(size.width / 1600, size.height / 1000)
            ctx.translateBy(x: (size.width - 1600 * k) / 2, y: (size.height - 1000 * k) / 2)
            ctx.scaleBy(x: k, y: k)
            let dusk = ["#2b2a4a", "#4a3a63", "#7b4a6b", "#c0606a", "#e98d68"], day = ["#5aa9e6", "#7cc0ef", "#a3d5f5", "#cbe8f8", "#eaf6fc"]
            let bands = sky ? day : dusk
            for (i, (y, h)) in [(-400.0, 560.0), (160, 140), (300, 110), (410, 90), (500, 120)].enumerated() {
                ctx.fill(Path(CGRect(x: -200, y: y, width: 2000, height: h)), with: .color(Color(hex: bands[i])))
            }
            ctx.fill(Path(ellipseIn: CGRect(x: 940, y: 400, width: 240, height: 240)), with: .color(Color(hex: sky ? "#fffbe8" : "#f6c76b")))
            func ridge(_ off: Double, _ base: Double, _ amp: Double, _ per: Double, _ col: String) {
                var p = Path()
                p.move(to: CGPoint(x: -50, y: 1000))
                for x in stride(from: -50.0, through: 1650, by: 40) {
                    let u = (x + off) / per, tri = abs((u.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1) - 0.5) * 2
                    p.addLine(to: CGPoint(x: x, y: base - amp * (0.55 * tri + 0.45 * abs(sin(u * 2.3)))))
                }
                p.addLine(to: CGPoint(x: 1650, y: 1000))
                ctx.fill(p, with: .color(Color(hex: col)))
            }
            ridge(120, 560, 150, 520, sky ? "#8fb9c9" : "#3c2f52")
            ridge(700, 650, 110, 380, sky ? "#5f9a6e" : "#2a2440")
            var ground = Path()
            ground.move(to: CGPoint(x: -50, y: 740))
            ground.addQuadCurve(to: CGPoint(x: 1650, y: 750), control: CGPoint(x: 800, y: 660))
            ground.addLine(to: CGPoint(x: 1650, y: 1050))
            ground.addLine(to: CGPoint(x: -50, y: 1050))
            ctx.fill(ground, with: .color(Color(hex: sky ? "#7fb069" : "#14141f")))
            var road = Path()
            road.addLines([CGPoint(x: 785, y: 700), CGPoint(x: 815, y: 700), CGPoint(x: 1080, y: 1000), CGPoint(x: 520, y: 1000)])
            ctx.fill(road, with: .color(Color(hex: sky ? "#8a8a8a" : "#2e2a3c")))
            for i in 0..<9 {
                let p = Double(i) / 9, y = 700 + 300 * p * p, w = 2 + 14 * p * p, h = 4 + 46 * p * p
                ctx.fill(Path(CGRect(x: 800 - w / 2, y: y, width: w, height: h)), with: .color(Color(hex: sky ? "#ffffff" : "#e8b44a").opacity(0.35 + 0.5 * p)))
            }
            for i in 0..<9 {
                let side = i % 2 == 1 ? 1.0 : -1.0, p = Double(i) / 9, sc = 0.25 + 1.6 * p * p
                let x = 800 + side * (140 + 760 * p * p), base = 712 + 300 * p * p
                var t = Path()
                t.addLines([CGPoint(x: x - 46 * sc, y: base), CGPoint(x: x, y: base - 190 * sc), CGPoint(x: x + 46 * sc, y: base)])
                ctx.fill(t, with: .color(Color(hex: sky ? "#2f5d3a" : "#1a1a2b")))
            }
        }
    }
}

private extension Color {
    init(hex: String) {
        let v = Int(hex.dropFirst(), radix: 16) ?? 0
        self.init(red: Double(v >> 16 & 0xff) / 255, green: Double(v >> 8 & 0xff) / 255, blue: Double(v & 0xff) / 255)
    }
}
