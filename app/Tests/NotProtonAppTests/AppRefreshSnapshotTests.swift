import AppKit
import ObjectiveC
import ScreenCaptureKit
import SwiftUI
import Testing
@testable import NotProtonApp

// Evidence PNGs of the game page and « Apps en arrière-plan », French and English, light and dark.
// Runs only with CARTOUCHE_APP_REFRESH_SNAPSHOTS=<folder>. Each panel is ours alone: built-in display,
// non-activating, ignoring the mouse, captured by itself (never the screen).
@MainActor
@Suite("App refresh snapshots", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["CARTOUCHE_APP_REFRESH_SNAPSHOTS"] != nil))
struct AppRefreshSnapshotTests {
    let folder = URL(filePath: ProcessInfo.processInfo.environment["CARTOUCHE_APP_REFRESH_SNAPSHOTS"] ?? "/tmp")
    static let languages = ["fr", "en"]

    // MARK: Game page

    @Test func gamePage() async throws {
        let fixture = try SteamFixture("refresh-shots")
        defer { fixture.remove() }
        try fixture.writeExport()
        try fixture.addArt(SteamFixture.apps.map(\.id))
        let scratch = ScratchDefaults()
        let compat = try await fixtureCompat(fixture.root, defaults: scratch)
        for id in [1_245_620, 367_520, 730] { await compat.openGame(appID: id) }
        let model = libraryModel(fixture, defaults: scratch)
        await model.load()
        let build = try #require(RunnerManifest.current().builds.first { $0.origin == .cartouche })
        model.runners = [Runner(id: build.id, kind: .wineBuild, version: build.version, displayVersion: build.displayVersion,
                                flavors: [.rosetta], state: .ready, build: nil, source: nil, isInstalled: true)]
        model.backendAvailability = BackendAvailability(d3dMetalRunners: [build.id], crossOverWine: [build.id])
        model.antiCheat = { game in game.steamAppID.flatMap { compat.antiCheat(appID: $0)?.name } }
        let actions = GameActionRunner(model: model, open: { _ in })
        defer { unpin() }
        let idle = ActivitySnapshotTests().center()
        let playing = ActivitySnapshotTests().center()
        playing.apply(SteamActivitySnapshot(runningAppID: 730))
        let states: [(String, String, ActivityCenter, Bool, CGFloat)] = [
            ("game-normal", "steam:367520", idle, false, 980),
            ("game-advanced", "steam:367520", idle, true, 1640),
            ("game-playing", "steam:730", playing, false, 980),
            ("game-anticheat", "steam:1245620", idle, true, 1640),
        ]
        for language in Self.languages {
            pin(language)
            for dark in [false, true] {
                for (name, id, activity, open, height) in states {
                    let game = try #require(model.game(id))
                    let panel = GamePanel(game: game, model: model, compat: compat, actions: actions)
                        .environment(\.covers, fixture.covers())
                        .environment(\.activity, activity)
                        .environment(\.advancedOpen, open)
                        .environment(\.glassMode, .classic)
                        .environment(\.locale, Locale(identifier: language))
                        .frame(width: Glass.panelWidth, height: height)
                        .background(Glass.window)
                    try await capture(panel, dark: dark, to: folder.appending(path: "\(name)-\(language)-\(dark ? "dark" : "light").png"))
                }
            }
        }
    }

    // MARK: Apps en arrière-plan

    @Test func backgroundApps() async throws {
        defer { unpin() }
        for language in Self.languages {
            pin(language)
            for dark in [false, true] {
                for (name, load, mode) in [("apps-normal", Load.normal, BackgroundAppsPresenter.Mode.manual),
                                           ("apps-overloaded", .over, .manual),
                                           ("apps-empty", .empty, .manual),
                                           ("apps-on-play", .over, .play)] {
                    let monitor = try await Self.monitor(load)
                    let presenter = BackgroundAppsPresenter()
                    if mode == .play { presenter.beforePlay(overloaded: true) {} } else { presenter.show(mode) }
                    let view = BackgroundAppsView(monitor: monitor, presenter: presenter, maxHeight: 900)
                        .frame(width: BackgroundAppsGrid.maxWidth)
                        .background(Glass.window)
                        .environment(\.locale, Locale(identifier: language))
                    try await capture(view, dark: dark, to: folder.appending(path: "\(name)-\(language)-\(dark ? "dark" : "light").png"))
                    monitor.stopViewing()
                }
            }
        }
    }

    enum Load { case normal, over, empty }

    // apps: where the bundles sit; a folder that does not exist gives every row the generic icon
    static func monitor(_ load: Load, apps: String = "/Applications") async throws -> ResourceMonitor {
        let gib: UInt64 = 1 << 30
        let second: UInt64 = 1_000_000_000
        // name, cpu % of the Mac, gpu %, memory GB, bundle
        var rows: [(String, Double, Double, Double, String)] = [
            ("Google Chrome", 34, 9, 3.8, "\(apps)/Google Chrome.app"),
            ("Photos", 21, 18, 1.7, "\(apps)/Photos.app"),
            ("Docker Desktop", 13, 0, 3.1, "\(apps)/Docker.app"),
            ("Creative Cloud", 6, 2, 1.1, "\(apps)/Creative Cloud.app"),
            ("Xcode", 4, 1, 2.4, "\(apps)/Xcode.app"),
            ("Spotlight", 3, 0, 0.2, "/System/Library/CoreServices/Spotlight.app"),
            ("1Password", 2, 0, 0.4, "\(apps)/1Password.app"),
        ]
        if load == .over { rows[0].1 = 58; rows[0].2 = 14; rows[1].1 = 24; rows[1].2 = 31 }
        if load == .empty { rows = rows.filter { $0.0 == "Spotlight" || $0.0 == "1Password" }.map { ($0.0, 1, 0, $0.3, $0.4) } }
        let cores = 8
        func processes(_ at: Double) -> [ProcessReading] {
            rows.enumerated().map { i, r in
                let name = URL(filePath: r.4).deletingPathExtension().lastPathComponent
                return ProcessReading(pid: pid_t(90_001 + i), parent: 1, uid: getuid(), name: name,
                                      path: r.4 + "/Contents/MacOS/" + name, started: 1000,
                                      cpuTime: UInt64(at * r.1 / 100 * Double(cores) * Double(second)),
                                      footprint: UInt64(r.3 * Double(gib)))
            }
        }
        func gpu(_ at: Double) -> [pid_t: UInt64] {
            Dictionary(uniqueKeysWithValues: rows.enumerated().map { (pid_t(90_001 + $0), UInt64(at * $1.2 / 100 * Double(second))) })
        }
        let busy: UInt64 = load == .over ? 92 : load == .empty ? 6 : 41
        let memory = MemoryReading(pressure: load == .over ? .warning : .normal, swapUsed: UInt64((load == .over ? 2.4 : 0.3) * Double(gib)),
                                   physical: 24 * gib, used: UInt64((load == .over ? 21.6 : load == .empty ? 9.8 : 17.1) * Double(gib)))
        let readings = [0.0, 1.0].map { at in
            ResourceReading(time: UInt64(at * Double(second)) + 1, processes: processes(at), cpuBusy: UInt64(at) * busy,
                            cpuTotal: UInt64(at) * 100, cores: cores,
                            gpu: GPUReading(device: load == .empty ? 3 : 22, perProcess: gpu(at), names: [:]), memory: memory)
        }
        let dir = try scratchDirectory("refresh-shots-paused")
        let paused = PausedProcesses(file: dir.appending(path: "paused.json"), signaller: RecordingSignaller(starts: [:]),
                                     crashGuard: RecordingGuard())
        let defaults = try #require(UserDefaults(suiteName: "refresh-shots-\(UUID().uuidString)"))
        let monitor = ResourceMonitor(source: ScriptedSource(readings), paused: paused, actions: RecordingActions(), defaults: defaults)
        monitor.thresholds.otherCPU = 70
        monitor.userProtected = ["1Password"]
        monitor.apps = {
            Dictionary(uniqueKeysWithValues: rows.enumerated().map { i, r in
                (pid_t(90_001 + i), RunningAppInfo(name: r.0, bundleID: "com.example.\(i)", bundlePath: r.4))
            })
        }
        await monitor.refresh()
        await monitor.refresh()
        return monitor
    }

    // MARK: Capture

    // The app's strings follow the pinned language too: Bundle.main answers from the module's lproj
    func pin(_ language: String) {
        OverlayText.use(language: language)
        PinnedBundle.language = OverlayText.bundle
        if !(Bundle.main is PinnedBundle) { object_setClass(Bundle.main, PinnedBundle.self) }
    }

    func unpin() {
        PinnedBundle.language = nil
        if Bundle.main is PinnedBundle { object_setClass(Bundle.main, Bundle.self) }
        OverlayText.use(language: "en")
    }

    func capture<V: View>(_ view: V, dark: Bool, to url: URL) async throws {
        let screen = NSScreen.screens.first { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID).map { CGDisplayIsBuiltin($0) != 0 } ?? false
        }
        let builtin = try #require(screen, "no built-in display")
        let host = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light))
        let size = host.fittingSize
        let panel = NSPanel(contentRect: CGRect(origin: builtin.frame.origin, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.ignoresMouseEvents = true
        panel.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        panel.contentView = host
        panel.setFrame(CGRect(origin: builtin.frame.origin, size: size), display: false)
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil); panel.contentView = nil }
        try await Task.sleep(for: .seconds(1.2))
        let rep: NSBitmapImageRep
        if let image = try? await WhatsNewSnapshotTests().windowImage(panel, size: size, scale: builtin.backingScaleFactor) {
            rep = NSBitmapImageRep(cgImage: image)
        } else {
            rep = try #require(renderedBitmap(host))
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #require(rep.representation(using: .png, properties: [:])).write(to: url)
    }
}

private final class PinnedBundle: Bundle, @unchecked Sendable {
    nonisolated(unsafe) static var language: Bundle?

    override func localizedString(forKey key: String, value: String?, table tableName: String?) -> String {
        if let pinned = Self.language { return pinned.localizedString(forKey: key, value: value, table: tableName) }
        return super.localizedString(forKey: key, value: value, table: tableName)
    }

    // SwiftUI asks for a localization by name; every variant answers from the pinned table
    @objc(localizedStringForKey:value:table:localization:)
    func pinned(_ key: String, value: String?, table: String?, localization: String?) -> String { pinnedText(key, value, table) }
    @objc(_localizedStringForKey:value:table:localizations:)
    func pinnedPrivate(_ key: String, value: String?, table: String?, localizations: [Any]?) -> String { pinnedText(key, value, table) }
    @objc(localizedAttributedStringForKey:value:table:localization:)
    func pinnedAttributed(_ key: String, value: String?, table: String?, localization: String?) -> NSAttributedString {
        NSAttributedString(string: pinnedText(key, value, table))
    }

    private func pinnedText(_ key: String, _ value: String?, _ table: String?) -> String {
        (Self.language ?? Bundle(for: PinnedBundle.self)).localizedString(forKey: key, value: value, table: table)
    }

    override var localizations: [String] { Self.language?.localizations ?? super.localizations }
    override var preferredLocalizations: [String] { Self.language?.preferredLocalizations ?? super.preferredLocalizations }
    override func path(forResource name: String?, ofType ext: String?) -> String? {
        Self.language?.path(forResource: name, ofType: ext) ?? super.path(forResource: name, ofType: ext)
    }
    override func url(forResource name: String?, withExtension ext: String?) -> URL? {
        Self.language?.url(forResource: name, withExtension: ext) ?? super.url(forResource: name, withExtension: ext)
    }
}
