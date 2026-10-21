import AppKit
import Foundation
import RetroArchKit
import Synchronization
import SwiftUI
import Testing
import Vision

@testable import NotProtonApp

// A web of fixed answers for URLSession: the buildbot, the libretro database
// and libretro-thumbnails, each test on a host of its own
final class StubWeb: URLProtocol, @unchecked Sendable {

    private struct State {
        var files: [String: Data] = [:]
        var requests: [String] = []
        var offline: Set<String> = []
    }

    private static let state = Mutex(State())

    let host = "fixture-\(UUID().uuidString.prefix(8).lowercased()).test"

    var base: URL { URL(string: "https://\(host)/")! }

    func put(_ path: String, _ data: Data) { Self.state.withLock { $0.files[host + path] = data } }

    // Every request to this host fails as if the Mac were offline
    func goOffline() { Self.state.withLock { _ = $0.offline.insert(host) } }

    var requests: [String] {
        Self.state.withLock { state in state.requests.filter { $0.hasPrefix(host) }.map { String($0.dropFirst(host.count)) } }
    }

    var session: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubWeb.self]
        return URLSession(configuration: config)
    }

    var fetch: @Sendable (URL) async throws -> (Data, Int) {
        let session = session
        return { url in
            let (data, response) = try await session.data(from: url)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".test") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host else { return }
        // The path as sent, percent escapes kept, so tests see what went out
        let path = url.path(percentEncoded: true)
        let (data, offline) = Self.state.withLock { state -> (Data?, Bool) in
            state.requests.append(host + path)
            return (state.files[host + path], state.offline.contains(host))
        }
        if offline {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: data == nil ? 404 : 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

enum ConsoleFixtures {

    // What the buildbot serves for a core: a zip holding a Mach-O header
    static func fakeCore(_ build: String) -> Data {
        Data([0xCF, 0xFA, 0xED, 0xFE]) + Data("cartouche test core \(build)".utf8)
    }

    // zip is waited on synchronously, so it runs off the caller: a ConsoleScene lives on the main actor
    static func zip(_ files: [String: Data], in work: URL) async throws -> Data {
        try await offMain {
            let folder = work.appending(path: "zip-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            for (name, data) in files { try data.write(to: folder.appending(path: name)) }
            let archive = folder.appending(path: "out.zip")
            let zip = Process()
            zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            zip.currentDirectoryURL = folder
            zip.arguments = ["-q", "-X", archive.path(percentEncoded: false)] + files.keys.sorted()
            try zip.run()
            zip.waitUntilExit()
            return try Data(contentsOf: archive)
        }
    }

    static func info(_ core: String, firmware: [(String, String)] = []) -> Data {
        var text = "display_name = \"\(ConsoleCatalog.coreName(core))\"\n"
        text += "firmware_count = \(firmware.count)\n"
        var notes: [String] = []
        for (i, (name, md5)) in firmware.enumerated() {
            text += "firmware\(i)_desc = \"\(name)\"\nfirmware\(i)_path = \"\(name)\"\nfirmware\(i)_opt = \"true\"\n"
            notes.append("(!) \(name) (md5): \(md5)")
        }
        text += "notes = \"\(notes.joined(separator: "|"))\"\n"
        return Data(text.utf8)
    }

    // A homebrew SNES cartridge written by the test: 32 KiB of LoROM, its
    // header named, nothing from any published game
    static func homebrewSNES(title: String = "CARTOUCHE HOMEBREW", fill: UInt8 = 0x42) -> Data {
        var rom = Data(repeating: fill, count: 32 * 1024)
        let name = Array(title.utf8.prefix(21)) + Array(repeating: UInt8(0x20), count: max(0, 21 - title.utf8.count))
        rom.replaceSubrange(0x7FC0..<0x7FD5, with: name)
        rom[0x7FD5] = 0x20
        return rom
    }

    static func installDatabase(in paths: RetroArchPaths) throws {
        let rows = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "../../../retroarch/Tests/RetroArchKitTests/Fixtures/database/rows.json").standardized
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: rows)) as? [String: Any] ?? [:]
        try FileManager.default.createDirectory(at: paths.database, withIntermediateDirectories: true)
        for (system, value) in json where !system.hasPrefix("_") {
            let entries = (value as? [[String: Any]] ?? []).map { row in
                DatabaseEntry(name: row["name"] as? String ?? "", romName: row["rom_name"] as? String,
                              crc: (row["crc"] as? String).flatMap { UInt32($0, radix: 16) },
                              md5: row["md5"] as? String, sha1: row["sha1"] as? String,
                              serial: row["serial"] as? String, size: (row["size"] as? NSNumber)?.uint64Value)
            }
            try RDB.write(entries).write(to: paths.database.appending(path: "\(system).rdb"))
        }
    }

    // A PlayStation disc as Redump lays it out, its track booting the serial
    @discardableResult
    static func disc(_ name: String, serial: String, in folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var track = Data(repeating: 0, count: 2352 * 26)
        let boot = Data("BOOT = cdrom:\\\(serial);1\r\nTCB = 4\r\n".utf8)
        let at = 2352 * 24 + 24
        track.replaceSubrange(at..<(at + boot.count), with: boot)
        try track.write(to: folder.appending(path: "\(name).bin"))
        let cue = folder.appending(path: "\(name).cue")
        try "FILE \"\(name).bin\" BINARY\n  TRACK 01 MODE2/2352\n    INDEX 01 00:00:00\n"
            .write(to: cue, atomically: true, encoding: .utf8)
        return cue
    }

    static let gameBoy: [(file: String, title: String, fill: UInt8)] = [
        ("quest.gb", "CARTOUCHE QUEST", 0), ("puzzle.gb", "CARTOUCHE PUZZL", 1),
        ("race.gb", "CARTOUCHE RACE", 2), ("maze.gb", "CARTOUCHE MAZE", 3),
    ]

    // A homebrew Game Boy cartridge: 32 KiB, the logo and title in the header
    static func homebrewGB(title: String, fill: UInt8 = 0x00) -> Data {
        var rom = Data(repeating: fill, count: 32 * 1024)
        rom.replaceSubrange(0x104..<0x134, with: CartHeader.gameBoyLogo)
        let name = Array(title.utf8.prefix(15))
        rom.replaceSubrange(0x134..<(0x134 + name.count), with: name)
        return rom
    }

    // A homebrew Game Boy Advance cartridge, as make_world.py writes it
    static func homebrewGBA(title: String, code: String = "CT00", fill: UInt8 = 0x00) -> Data {
        var rom = Data(repeating: fill, count: 32 * 1024)
        rom.replaceSubrange(0x00..<0x04, with: [0x2E, 0x00, 0x00, 0xEA])
        rom.replaceSubrange(0x04..<0xA0, with: CartHeader.advanceLogo)
        var name = Array(title.utf8.prefix(12))
        while name.count < 12 { name.append(0) }
        rom.replaceSubrange(0xA0..<0xAC, with: name)
        var gameCode = Array(code.utf8.prefix(4))
        while gameCode.count < 4 { gameCode.append(0x20) }
        rom.replaceSubrange(0xAC..<0xB0, with: gameCode)
        rom[0xB0] = 0x34
        rom[0xB1] = 0x32
        rom[0xB2] = 0x96
        let sum = rom[0xA0..<0xBD].reduce(0) { $0 + Int($1) }
        rom[0xBD] = UInt8(truncatingIfNeeded: -(0x19 + sum))
        return rom
    }
}

// Everything a console test needs, under one scratch folder: Cartouche's
// RetroArch folder, the stub buildbot, a library and the console center
@MainActor
final class ConsoleScene {
    let fixture: SteamFixture
    let scratch = ScratchDefaults()
    let web = StubWeb()
    let paths: RetroArchPaths
    let cores: CoreManager
    let settings: ConsolesSettingsModel
    let library: LibraryModel
    let database: ContentDatabase
    let center: ConsoleCenter
    // Settings > Library's game folders, in the scene's own defaults
    let folders: GameFolders
    var work: URL { fixture.root }

    init(_ label: String, steamGames: Bool = false) async throws {
        fixture = try SteamFixture("console-\(label)")
        if steamGames { try fixture.writeExport() }
        paths = RetroArchPaths(root: fixture.root.appending(path: "retroarch", directoryHint: .isDirectory))
        let source = CoreSource(cores: web.base.appending(path: "nightly/"), info: web.base.appending(path: "info.zip"))
        let bin = fixture.root.appending(path: "bin", directoryHint: .isDirectory)
        // The Trash in a test moves into the scene's own bin/, never the user's real Trash
        cores = CoreManager(paths: paths, source: source, session: web.session) { url in
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: url, to: bin.appending(path: url.lastPathComponent))
        }
        settings = ConsolesSettingsModel(paths: paths, includedApp: fixture.root.appending(path: "RetroArch.app"),
                                         cores: cores, official: OfficialRelease(paths: paths), probe: { _ in nil })
        library = libraryModel(fixture, installed: steamGames, defaults: scratch)
        try ConsoleFixtures.installDatabase(in: paths)
        // Only the recorded rows: the scene never reaches libretro-database
        database = ContentDatabase(paths: paths, fetch: { _ in throw URLError(.notConnectedToInternet) })
        center = ConsoleCenter(settings: settings, cores: cores, library: library, database: database)
        folders = GameFolders(defaults: scratch.defaults)
        center.covers = covers
        center.folderList = folders
        // The session record lives in the scene, never the user's support folder
        center.sessions = SessionRecords(file: fixture.root.appending(path: "support/console-session.json"))
        // Standalone emulators are looked for in the scene, never in /Applications
        center.emulators.detector = EmulatorDetector(folders: [applications])
        var infos: [String: Data] = [:]
        for console in ConsoleCatalog.all {
            web.put("/nightly/\(console.core)_libretro.dylib.zip",
                    try await ConsoleFixtures.zip(["\(console.core)_libretro.dylib": ConsoleFixtures.fakeCore("1")], in: fixture.root))
            infos["\(console.core)_libretro.info"] = console.id == "ps1"
                ? ConsoleFixtures.info(console.core, firmware: [("scph5501.bin", "490f666e1afb15b7362b406ed1cea246")])
                : ConsoleFixtures.info(console.core)
        }
        web.put("/info.zip", try await ConsoleFixtures.zip(infos, in: fixture.root))
    }

    func remove() { fixture.remove() }

    // The scene's own Applications folder, for fake standalone emulator apps
    var applications: URL { work.appending(path: "Applications", directoryHint: .isDirectory) }
    // Covers from a cache in the scene, never the network

    var covers: CoverStore {
        var covers = CoverStore(steamCache: work.appending(path: "no-steam"), cache: work.appending(path: "covers"),
                                fetch: { _ in throw URLError(.notConnectedToInternet) })
        covers.thumbnails = Thumbnails(cache: work.appending(path: "covers/consoles"), fetch: { _ in throw URLError(.notConnectedToInternet) })
        return covers
    }

    var coresFolder: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: paths.cores.path(percentEncoded: false))) ?? []).sorted()
    }

    var coreRequests: [String] { web.requests.filter { $0.hasPrefix("/nightly/") } }
}

// Renders a view in an invisible window, as LibraryWindowTests does, and reads
// back the text a person would see. Writes the PNG when CARTOUCHE_SNAPSHOTS is set.
@MainActor
func renderedTexts<V: View>(_ view: V, size: CGSize, named name: String? = nil, dark: Bool = false,
                            settle: Double = 0.4) async throws -> [String] {
    let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .fullSizeContentView],
                          backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    window.isReleasedWhenClosed = false
    window.animationBehavior = .none
    window.contentViewController = NSHostingController(rootView: view.environment(\.colorScheme, dark ? .dark : .light))
    window.setContentSize(size)
    window.alphaValue = 0
    window.ignoresMouseEvents = true
    window.orderFrontRegardless()
    let end = Date().addingTimeInterval(settle)
    while Date() < end { try? await Task.sleep(for: .milliseconds(20)) }
    let frame = window.contentView?.superview ?? window.contentView!
    let rep = try #require(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
    frame.cacheDisplay(in: frame.bounds, to: rep)
    window.contentViewController = nil
    window.orderOut(nil)
    window.close()
    if let name, let folder = ProcessInfo.processInfo.environment["CARTOUCHE_SNAPSHOTS"] {
        let url = URL(filePath: folder).appending(path: "\(name)-\(dark ? "dark" : "light").png")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
    let image = try #require(rep.cgImage)
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    try VNImageRequestHandler(cgImage: image).perform([request])
    return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
}

// Text recognition reads a glyph as a bullet and some Latin letters as their
// Cyrillic look-alikes; this compares what a person would read
func seen(_ texts: [String], _ wanted: String) -> Bool {
    let lookAlikes: [Character: Character] = [
        "А": "A", "В": "B", "Е": "E", "К": "K", "М": "M", "Н": "H", "О": "O", "Р": "P", "С": "C", "Т": "T",
        "Х": "X", "а": "a", "е": "e", "о": "o", "р": "p", "с": "c", "у": "y", "х": "x",
    ]
    return texts.contains { String($0.map { lookAlikes[$0] ?? $0 }).contains(wanted) }
}
