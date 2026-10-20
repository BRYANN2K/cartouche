import Foundation
import RetroArchKit

@testable import NotProtonApp

// Stands in for RetroArch in the app's tests: records what it is asked, and on
// Quit writes the auto state and its picture as RetroArch does
actor FakeRunner: ConsoleRunning {
    private(set) var requests: [PlayRequest] = []
    private(set) var looks: [ConsoleLook] = []
    private(set) var discs: [Int] = []
    private(set) var inputLag: [Bool] = []
    private(set) var quits = 0
    private var started: ContinuousClock.Instant?
    private var exitedByItself = false
    private var fakePlayed: Duration?
    let states: URL
    let picture: Data
    // The process the session record watches for; nil unless the test gives one
    nonisolated let processIdentifier: Int32?

    init(states: URL, picture: Data, pid: Int32? = nil) {
        self.states = states
        self.picture = picture
        self.processIdentifier = pid
    }

    var isPlaying: Bool { started != nil }

    func play(_ request: PlayRequest) async throws {
        requests.append(request)
        started = .now
    }

    func setLook(_ look: ConsoleLook) async throws { looks.append(look) }
    func setLowerInputLag(_ on: Bool) async throws { inputLag.append(on) }
    func setHardcore(_ on: Bool) async throws {}
    func setDisc(_ disc: Int) async throws { discs.append(disc) }

    func pretend(played: Duration) { fakePlayed = played }

    func quit() async -> PlayReport {
        quits += 1
        let played = fakePlayed ?? started.map { .now - $0 } ?? .zero
        if started != nil, let content = requests.last?.content {
            let folder = states.appending(path: "Fake Core", directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let name = content.deletingPathExtension().lastPathComponent
            try? Data("state".utf8).write(to: folder.appending(path: "\(name).state.auto"))
            try? picture.write(to: folder.appending(path: "\(name).state.auto.png"))
        }
        started = nil
        return PlayReport(stop: StopReport(way: .quit, duration: .milliseconds(25)), played: played)
    }

    // The user quits RetroArch from its own window
    func exitByItself() { exitedByItself = true }

    func ended() async -> PlayReport? {
        guard exitedByItself, started != nil else { return nil }
        exitedByItself = false
        return await quit()
    }
}

extension ConsoleScene {
    // A game of the console, its file the user's, in the library
    @discardableResult
    func addGame(console: String, name: String, databaseName: String? = nil, data: Data = ConsoleFixtures.homebrewSNES(),
                 ext: String = "sfc", discs: Int = 0) async throws -> ConsoleGame {
        let folder = work.appending(path: "My Games", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var file = folder.appending(path: "\(name).\(ext)")
        var discFiles: [URL] = []
        if discs > 1 {
            for i in 1...discs {
                discFiles.append(try ConsoleFixtures.disc("\(name) (Disc \(i))", serial: "SLUS_999.0\(i + 1)", in: folder))
            }
            file = folder.appending(path: "\(name).m3u")
            try discFiles.map(\.lastPathComponent).joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        } else {
            try data.write(to: file)
        }
        let game = ConsoleGame(console: console, name: name, databaseName: databaseName, file: file, discs: discFiles,
                               identifiedBy: databaseName == nil ? .chosen : .checksum)
        if !center.isAdded(console) { await center.add([console]) }
        try await center.store.add([game])
        await center.reload()
        return game
    }

    // RetroArch's states for a game, with pictures, as it writes them
    func writeState(_ game: ConsoleGame, slot: Int?, picture: Data, age: TimeInterval) throws {
        let folder = paths.states.appending(path: "Snes9x", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "\(game.contentName).state" + (slot.map { $0 == 0 ? "" : String($0) } ?? ".auto"))
        try Data("state".utf8).write(to: file)
        try picture.write(to: file.appendingPathExtension("png"))
        for url in [file, file.appendingPathExtension("png")] {
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -age)], ofItemAtPath: url.path)
        }
    }

    func useFakeRunner(picture: Data, pid: Int32? = nil) -> FakeRunner {
        let runner = FakeRunner(states: paths.states, picture: picture, pid: pid)
        center.makeRunner = { _ in runner }
        return runner
    }
}
