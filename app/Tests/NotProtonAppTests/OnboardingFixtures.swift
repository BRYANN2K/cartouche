import AppKit
import Foundation
import RetroArchKit
import SwiftUI
import Synchronization

@testable import NotProtonApp

// Everything the onboarding touches, as fakes that count what was asked of them.
// Nothing here reads the real Steam folder, ~/Library or ~/Downloads, downloads
// anything, or reaches TCC.
@MainActor
final class OnboardingScene {

    final class Counts: Sendable {
        struct State {
            var runnerInstalls: [String] = []
            var consoleAdds: [String] = []
            var steamInstalls = 0
            // The fake console shelf and runners folder
            var shelf: [String] = []
            var runnerInstalled = false
        }

        let state = Mutex(State())
        var runnerInstalls: [String] { state.withLock { $0.runnerInstalls } }
        var consoleAdds: [String] { state.withLock { $0.consoleAdds } }
        var steamInstalls: Int { state.withLock { $0.steamInstalls } }
    }

    let fixture: SteamFixture
    let scratch: ScratchDefaults
    let home: URL
    let counts = Counts()
    let tcc: FakeTCC
    let library: LibraryModel
    let folders: GameFolders
    let privacy: PrivacyChoices
    let retroarch: RetroArchPaths
    var findings: MacFindings
    var consoles: ConsoleSetup?

    nonisolated static let wine = RunnerManifest.Build(
        id: "wine-stable-11.0_1", kind: "wineBuild", origin: .winehq, name: "Wine", version: "11.0_1",
        displayVersion: "11.0", url: URL(string: "https://github.com/Gcenx/macOS_Wine_builds/releases/download/11.0_1/wine.tar.xz")!,
        size: 1, sha256: String(repeating: "0", count: 64), root: "wine", loader: "bin/wine", flavors: ["rosetta"])

    init(_ label: String, scratch: ScratchDefaults = ScratchDefaults(), steam: Bool = true) throws {
        fixture = try SteamFixture("onboarding-\(label)")
        self.scratch = scratch
        home = fixture.root.appending(path: "home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        tcc = FakeTCC()
        library = libraryModel(fixture, running: false, installed: steam, defaults: scratch)
        folders = GameFolders(defaults: scratch.defaults)
        privacy = PrivacyChoices(defaults: scratch.defaults)
        retroarch = RetroArchPaths(root: fixture.root.appending(path: "retroarch", directoryHint: .isDirectory))
        findings = MacFindings(
            steam: steam ? FoundSteam(account: SteamFixture.account, games: SteamFixture.apps.count) : nil,
            controllers: [FoundController(name: "DualSense Wireless Controller", battery: 80)],
            // Named under the real home folder so it reads ~/Games/ROMs; the fake scan never opens it
            folders: [FoundFolder(url: SupportPaths.home.appending(path: "Games/ROMs", directoryHint: .isDirectory), games: 76,
                                  consoles: ["gb": 37, "gba": 21, "ps1": 18])])
    }

    func remove() {
        let macos = fixture.steam.appending(path: "Steam.app/Contents/MacOS")
        chmod(macos.path(percentEncoded: false), 0o755)
        fixture.remove()
    }

    var store: OnboardingStore { OnboardingStore(defaults: scratch.defaults) }

    // A fake shelf by default; tests that download real fixture cores set `consoles`
    func consoleSetup() -> ConsoleSetup {
        if let consoles { return consoles }
        let counts = counts, paths = retroarch
        return ConsoleSetup(
            added: { counts.state.withLock { $0.shelf } },
            add: { id in
                counts.state.withLock {
                    $0.consoleAdds.append(id)
                    if !$0.shelf.contains(id) { $0.shelf.append(id) }
                }
            },
            bios: { BIOSChecker(paths: paths).status(for: $0) },
            biosFolder: paths.bios)
    }

    // A Steam.app in the fixture whose MacOS folder refuses writes, as App Management does
    func steamStep(blocked: Bool = true) throws -> SteamStep {
        let contents = fixture.steam.appending(path: "Steam.app/Contents")
        try FileManager.default.createDirectory(at: contents.appending(path: "MacOS"), withIntermediateDirectories: true)
        try Data("<plist/>".utf8).write(to: contents.appending(path: "Info.plist"))
        if blocked { chmod(contents.appending(path: "MacOS").path(percentEncoded: false), 0o555) }
        let target = contents.appending(path: "MacOS/cartouche.dylib")
        let center = makeCenter(tcc, scratch)
        let counts = counts
        return SteamStep(
            flow: PermissionFlow(center: center),
            install: {
                counts.state.withLock { $0.steamInstalls += 1 }
                try WriteRefused.catching(target) { try Data("x".utf8).write(to: target) }
            },
            relaunch: { _ in })
    }

    func model(steamBlocked: Bool = true) throws -> OnboardingModel {
        let found = findings, counts = counts
        let scan = MacScan(
            steam: { found.steam }, crossOver: { found.crossOver }, portingToolkit: { found.portingToolkit },
            controllers: { found.controllers }, folders: { found.folders })
        let runners = RunnerOffer(
            build: { Self.wine },
            isInstalled: { _ in counts.state.withLock { $0.runnerInstalled } },
            install: { build in
                counts.state.withLock {
                    $0.runnerInstalls.append(build.id)
                    $0.runnerInstalled = true
                }
            })
        return OnboardingModel(
            store: store, scan: scan, runners: runners, consoles: consoleSetup(),
            steamStep: try steamStep(blocked: steamBlocked), folders: folders, privacy: privacy, library: library)
    }

    var untouched: Bool {
        counts.runnerInstalls.isEmpty && counts.consoleAdds.isEmpty && counts.steamInstalls == 0
            && tcc.requests.isEmpty && folders.paths.isEmpty && privacy.fetchMacReports
            && !FileManager.default.fileExists(atPath: retroarch.root.path(percentEncoded: false))
    }

    func render(_ model: OnboardingModel, named name: String, modes: [GlassMode] = [.liquid, .classic]) async {
        useCartoucheIcon()
        for mode in modes {
            for dark in [false, true] {
                let view = OnboardingView(model: model)
                    .environment(\.covers, fixture.covers())
                    .environment(\.glassMode, mode)
                await sheetSnapshot(view, named: mode == .classic ? "\(name)-macos15" : name, dark: dark)
            }
        }
    }
}

// Serves fixture cores in place of the libretro buildbot, inside the test process.
// Each test gets its own host, so tests running at the same time do not mix.
final class StubBuildbot: URLProtocol, @unchecked Sendable {
    static let files = Mutex<[String: Data]>([:])
    static let requests = Mutex<[String]>([])

    static var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubBuildbot.self]
        return URLSession(configuration: configuration)
    }

    struct Site {
        let host: String

        init(_ label: String) { host = "buildbot-\(label).invalid" }

        var source: CoreSource {
            CoreSource(cores: URL(string: "https://\(host)/cores/")!, info: URL(string: "https://\(host)/info.zip")!)
        }

        var requests: [String] {
            StubBuildbot.requests.withLock { $0 }.filter { $0.hasPrefix(host + "/") }.map { String($0.dropFirst(host.count)) }
        }

        // A zip holding one core: any Mach-O passes the core check
        func serveCore(_ core: String, work: URL) throws {
            let folder = work.appending(path: "core-\(core)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let dylib = folder.appending(path: "\(core)_libretro.dylib")
            try? FileManager.default.removeItem(at: dylib)
            try FileManager.default.copyItem(at: URL(filePath: "/usr/bin/true"), to: dylib)
            let zip = folder.appending(path: "\(core)_libretro.dylib.zip")
            try? FileManager.default.removeItem(at: zip)
            let result = try Shell.run("/usr/bin/zip", ["-q", "-j", zip.path(percentEncoded: false), dylib.path(percentEncoded: false)])
            guard result.succeeded else { throw URLError(.cannotCreateFile) }
            let data = try Data(contentsOf: zip)
            StubBuildbot.files.withLock { $0["\(host)/cores/\(core)_libretro.dylib.zip"] = data }
        }

        func serveInfo(_ cores: [String], work: URL) throws {
            let folder = work.appending(path: "info")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var paths: [String] = []
            for core in cores {
                let info = folder.appending(path: "\(core)_libretro.info")
                try "display_name = \"\(core)\"\n".write(to: info, atomically: true, encoding: .utf8)
                paths.append(info.path(percentEncoded: false))
            }
            let zip = folder.appending(path: "info.zip")
            try? FileManager.default.removeItem(at: zip)
            let result = try Shell.run("/usr/bin/zip", ["-q", "-j", zip.path(percentEncoded: false)] + paths)
            guard result.succeeded else { throw URLError(.cannotCreateFile) }
            let data = try Data(contentsOf: zip)
            StubBuildbot.files.withLock { $0["\(host)/info.zip"] = data }
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".invalid") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let key = "\(request.url?.host ?? "")\(request.url?.path ?? "")"
        Self.requests.withLock { $0.append(key) }
        let body = Self.files.withLock { $0[key] }
        let response = HTTPURLResponse(url: request.url!, statusCode: body == nil ? 404 : 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// Renders the onboarding sheet as a window, like windowSnapshot, without the
// window's open and close animations. Each of those leaves a thread waiting on
// an animation an invisible window never finishes, and enough of them exhaust
// the dispatch thread pool for the tests that come after.
@MainActor
@discardableResult
func sheetSnapshot<V: View>(_ view: V, named name: String, size: CGSize = CGSize(width: 660, height: 620),
                            dark: Bool = false, settle: Double = 0.4) async -> CGSize {
    let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                          styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
    window.animationBehavior = .none
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    window.isReleasedWhenClosed = false
    window.contentViewController = NSHostingController(rootView: view)
    window.setContentSize(size)
    window.alphaValue = 0
    window.ignoresMouseEvents = true
    window.orderFrontRegardless()
    let end = Date().addingTimeInterval(settle)
    while Date() < end {
        try? await Task.sleep(for: .milliseconds(20))
    }
    let frame = window.contentView?.superview ?? window.contentView!
    if let folder = ProcessInfo.processInfo.environment["CARTOUCHE_SNAPSHOTS"],
       let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) {
        frame.cacheDisplay(in: frame.bounds, to: rep)
        let url = URL(filePath: folder).appending(path: "\(name)-\(dark ? "dark" : "light").png")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
    let shown = frame.bounds.size
    window.orderOut(nil)
    window.contentViewController = nil
    return shown
}

// The test runner has no icon of its own; the welcome step and the alert show the app's
@MainActor
func useCartoucheIcon() {
    let repo = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../..").standardizedFileURL
    if let icon = NSImage(contentsOf: repo.appending(path: "mockup/brand/cartouche-icon-default.svg")) {
        NSApplication.shared.applicationIconImage = icon
    }
}
