import AppKit
import Foundation
import SwiftUI

@testable import NotProtonApp

// A Steam folder in a scratch directory, shaped like ~/Library/Application Support/Steam
// on a Mac signed in as player42. Nothing here reads or writes the real one.
struct SteamFixture {

    struct App {
        let id: Int
        let name: String
        let installed: Bool
        // Days since last played, nil for never
        let played: Int?
        let minutes: Int
    }

    // The Steam games of the mockup, launcher.html
    static let apps: [App] = [
        App(id: 1_245_620, name: "Elden Ring", installed: true, played: 1, minutes: 954),
        App(id: 730, name: "Counter-Strike 2", installed: true, played: 7, minutes: 420),
        App(id: 1_172_470, name: "Apex Legends", installed: false, played: nil, minutes: 0),
        App(id: 1_174_180, name: "Red Dead Redemption 2", installed: true, played: 3, minutes: 450),
        App(id: 1_593_500, name: "God of War", installed: false, played: nil, minutes: 0),
        App(id: 1_091_500, name: "Cyberpunk 2077", installed: true, played: nil, minutes: 0),
        App(id: 1_086_940, name: "Baldur’s Gate 3", installed: true, played: nil, minutes: 0),
        App(id: 367_520, name: "Hollow Knight", installed: true, played: nil, minutes: 0),
    ]

    static let steamID = "76561198000000042"
    static let accountID = "39734314"
    static let account = "player42"

    let root: URL
    // One fixed instant anchors every LastPlayed the fixture writes, so a test
    // asserting "yesterday" cannot cross midnight between write and read
    let now = Date()
    var steam: URL { root.appending(path: "Steam") }
    var support: URL { root.appending(path: "Cartouche") }
    var caches: URL { root.appending(path: "Caches/covers") }
    var export: URL { support.appending(path: SteamExport.fileName) }
    // A second library on another disk, as libraryfolders.vdf lists it
    var external: URL { root.appending(path: "External/SteamLibrary") }

    init(_ label: String) throws {
        root = try scratchDirectory("steam-\(label)")
        for folder in [steam.appending(path: "steamapps"), steam.appending(path: "config"), support, caches,
                       external.appending(path: "steamapps"),
                       steam.appending(path: "userdata/\(Self.accountID)/config/cloudstorage")] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try write("config/loginusers.vdf", """
        "users"
        {
        \t"76561197960265999"
        \t{
        \t\t"AccountName"\t\t"someoneelse"
        \t\t"PersonaName"\t\t"Other"
        \t\t"MostRecent"\t\t"0"
        \t\t"Timestamp"\t\t"1700000000"
        \t}
        \t"\(Self.steamID)"
        \t{
        \t\t"AccountName"\t\t"\(Self.account)"
        \t\t"PersonaName"\t\t"Player 42"
        \t\t"MostRecent"\t\t"1"
        \t\t"Timestamp"\t\t"1790000000"
        \t}
        }
        """)
        try write("steamapps/libraryfolders.vdf", """
        "libraryfolders"
        {
        \t"0"
        \t{
        \t\t"path"\t\t"\(steam.path(percentEncoded: false))"
        \t\t"apps" { "1245620" "1" }
        \t}
        \t"1"
        \t{
        \t\t"path"\t\t"\(external.path(percentEncoded: false))"
        \t}
        }
        """)
        let now = Int(self.now.timeIntervalSince1970)
        for (i, app) in Self.apps.enumerated() where app.installed {
            // Half the games sit on the second disk
            let library = i % 2 == 0 ? steam : external
            try manifest(app, in: library, flags: 4, lastPlayed: app.played.map { now - $0 * 86400 } ?? 0)
        }
        // Being downloaded: not installed yet
        try manifest(App(id: 1_593_500, name: "God of War", installed: false, played: nil, minutes: 0),
                     in: steam, flags: 1026, lastPlayed: 0)
        // Steam's own runtime, never a game
        try manifest(App(id: 228_980, name: "Steamworks Common Redistributables", installed: true, played: nil, minutes: 0),
                     in: steam, flags: 4, lastPlayed: 0)

        var apps = ""
        for app in Self.apps where app.minutes > 0 {
            apps += "\"\(app.id)\" { \"LastPlayed\" \"\(now - (app.played ?? 0) * 86400)\" \"Playtime\" \"\(app.minutes)\" }\n"
        }
        try write("userdata/\(Self.accountID)/config/localconfig.vdf", """
        "UserLocalConfigStore"
        {
        \t"Software" { "Valve" { "Steam" { "Apps" {
        \(apps)
        \t} } } }
        }
        """)
        let rows: [[Any]] = [
            ["user-collections.uc-souls", ["key": "user-collections.uc-souls", "timestamp": 1,
                                            "value": #"{"id":"uc-souls","name":"Souls","added":[1245620,1174180,730],"removed":[730]}"#]],
            ["user-collections.favorite", ["key": "user-collections.favorite", "timestamp": 1,
                                            "value": #"{"id":"favorite","name":"","added":[730]}"#]],
            ["user-collections.uc-old", ["key": "user-collections.uc-old", "timestamp": 1, "is_deleted": true,
                                          "value": #"{"id":"uc-old","name":"Old","added":[367520]}"#]],
        ]
        try JSONSerialization.data(withJSONObject: rows)
            .write(to: steam.appending(path: "userdata/\(Self.accountID)/config/cloudstorage/cloud-storage-namespace-1.json"))
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func write(_ path: String, _ text: String) throws {
        try text.write(to: steam.appending(path: path), atomically: true, encoding: .utf8)
    }

    private func manifest(_ app: App, in library: URL, flags: Int, lastPlayed: Int) throws {
        let text = """
        "AppState"
        {
        \t"appid"\t\t"\(app.id)"
        \t"name"\t\t"\(app.name)"
        \t"StateFlags"\t\t"\(flags)"
        \t"installdir"\t\t"\(app.name)"
        \t"LastPlayed"\t\t"\(lastPlayed)"
        }
        """
        try text.write(to: library.appending(path: "steamapps/appmanifest_\(app.id).acf"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: library.appending(path: "steamapps/common/\(app.name)"),
                                                withIntermediateDirectories: true)
    }

    // What the running Steam client exports: every owned game, installed or not
    func writeExport(steamID: String = Self.steamID, apps: [App] = Self.apps, installed: Set<Int>? = nil) throws {
        let now = Int(self.now.timeIntervalSince1970)
        let doc = SteamExport(
            version: 1, generated: now, steamid: steamID,
            apps: apps.map { app in
                SteamExport.App(appid: app.id, name: app.name, installed: installed.map { $0.contains(app.id) } ?? app.installed,
                                lastPlayed: app.played.map { now - $0 * 86400 }, playtime: app.minutes, hidden: false)
            },
            collections: [SteamExport.Collection(id: "uc-souls", name: "Souls", apps: [1_245_620])])
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try JSONEncoder().encode(doc).write(to: export, options: .atomic)
    }

    func importer(installed: Bool = true, running: Bool) -> SteamLibraryImporter {
        SteamLibraryImporter(
            files: SteamLocalFiles(userData: steam), export: export,
            isInstalled: { installed }, isRunning: { running })
    }

    // Steam's library cache with art for some games, and Cartouche's cache with one more
    func addArt(_ ids: [Int]) throws {
        for (i, id) in ids.enumerated() {
            let name = Self.apps.first { $0.id == id }?.name ?? String(id)
            let folder = steam.appending(path: "appcache/librarycache/\(id)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Self.png(name, size: CGSize(width: 300, height: 450), hue: Double(i) / Double(max(ids.count, 1)))
                .write(to: folder.appending(path: "library_600x900.jpg"))
            try Self.png(name, size: CGSize(width: 960, height: 310), hue: Double(i) / Double(max(ids.count, 1)))
                .write(to: folder.appending(path: "library_hero.jpg"))
        }
    }

    func covers(fetch: @escaping CoverStore.Fetch = { _ in throw URLError(.notConnectedToInternet) }) -> CoverStore {
        CoverStore(steamCache: steam.appending(path: "appcache/librarycache"), cache: caches, fetch: fetch)
    }

    // A plain stand-in for box art, with the game's name on it
    static func png(_ text: String, size: CGSize, hue: Double) throws -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(hue: hue, saturation: 0.45, brightness: 0.45, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        (text as NSString).draw(in: NSRect(x: 10, y: size.height / 2 - 30, width: size.width - 20, height: 60), withAttributes: [
            .font: NSFont.boldSystemFont(ofSize: size.width / 12), .foregroundColor: NSColor.white, .paragraphStyle: style,
        ])
        NSGraphicsContext.restoreGraphicsState()
        return try require(rep.representation(using: .png, properties: [:]))
    }

    static func require<T>(_ value: T?) throws -> T {
        guard let value else { throw URLError(.cannotDecodeContentData) }
        return value
    }
}

private func require<T>(_ value: T?) throws -> T { try SteamFixture.require(value) }

// Every action a menu item list can run, children included
extension GameMenuItem {
    var flatActions: [GameAction] { (action.map { [$0] } ?? []) + children.flatMap(\.flatActions) }
}

@MainActor
func libraryModel(_ fixture: SteamFixture, running: Bool = true, installed: Bool = true, defaults: ScratchDefaults) -> LibraryModel {
    LibraryModel(store: LibraryStore(folder: fixture.support), importer: fixture.importer(installed: installed, running: running),
                 defaults: defaults.defaults)
}

// The 2026-10-19 compatibility fixture and MacGamingDB's recorded Elden Ring answer, on an M4
@MainActor
func fixtureCompat(_ work: URL, defaults: ScratchDefaults, macReports: Bool = true) async throws -> CompatibilityModel {
    let directory = work.appending(path: "compatibility")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: CompatFixture.gzip, to: directory.appending(path: "compat.json.gz"))
    let answer = try Data(contentsOf: CompatFixture.eldenRingAnswer)
    let choices = PrivacyChoices(defaults: defaults.defaults)
    choices.fetchMacReports = macReports
    let model = CompatibilityModel(
        client: CompatibilityClient(directory: directory),
        macGamingDB: MacGamingDBClient(directory: directory.appending(path: "macgamingdb")) { url in
            url.lastPathComponent == "1245620" ? (answer, 200) : (Data(), 404)
        },
        choices: choices)
    model.now = { CompatFixture.generated }
    model.chip = "M4"
    await model.load()
    return model
}

// Renders a whole window, title bar and toolbar included, for evidence screenshots.
// Writes PNGs only when CARTOUCHE_SNAPSHOTS names a folder.
@MainActor
@discardableResult
func windowSnapshot<V: View>(_ view: V, named name: String, size: CGSize = CGSize(width: 1280, height: 800),
                             dark: Bool = false, settle: Double = 0.4) async -> CGSize {
    let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
    // No window animation: each animated order-out left a thread stuck in the test process,
    // and past 64 of them the dispatch pool stops running work
    window.animationBehavior = .none
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    window.isReleasedWhenClosed = false
    let host = NSHostingController(rootView: view)
    window.contentViewController = host
    window.setContentSize(size)
    // On screen for the window server, so lists load their rows, yet invisible and
    // untouchable: nothing shows on the Mac's screen
    window.alphaValue = 0
    window.ignoresMouseEvents = true
    window.orderFrontRegardless()
    // Lets tasks, toolbars and the inspector settle
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
