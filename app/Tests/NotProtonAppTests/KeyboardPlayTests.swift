import CoreGraphics
import Foundation
import Testing

@testable import NotProtonApp

// A controller whose state the test sets
@MainActor
final class FakePad: PadReader {
    var state: PadState? = PadState()
    func read() -> PadState? { state }
}

// Records what would be posted. No test posts a real event into the session.
@MainActor
final class RecordingInputPoster: InputPoster {
    var posted: [InputEvent] = []
    func post(_ events: [InputEvent]) { posted += events }
}

@MainActor
final class FakeFocus: GameFocus {
    var front: String?
    func isFrontmost(_ game: Game) -> Bool { front == game.id }
}

@MainActor
final class FakeTap: KeyTapping {
    var table: [CGKeyCode: CGKeyCode] = [:]
    var refuses = false
    var starts = 0
    var stops = 0
    func start() -> Bool {
        starts += 1
        return !refuses
    }
    func stop() { stops += 1 }
}

@Suite("Play with a controller and key remapping")
@MainActor
struct KeyboardPlayTests {

    static let game = Game(id: "installer:hades", source: .installer, name: "Hades", installed: true)

    @Test("Buttons to keys, left stick to WASD, triggers to mouse buttons, right stick to the pointer")
    func translation() {
        var held = PadState()
        held.pressed = [.south, .rightTrigger]
        held.leftStick = CGPoint(x: 0.9, y: 0.8)
        held.rightStick = CGPoint(x: 0.5, y: 0)
        let down = KeyboardPlay.events(from: .idle, to: held)
        #expect(down.contains(.key(49, down: true)))   // Space
        #expect(down.contains(.key(13, down: true)))   // W
        #expect(down.contains(.key(2, down: true)))    // D
        #expect(down.contains(.mouseButton(.left, down: true)))
        #expect(down.contains(.mouseMove(dx: 7, dy: -0)))
        let up = KeyboardPlay.events(from: held, to: .idle)
        let released: Set<CGKeyCode> = Set(up.compactMap { event -> CGKeyCode? in
            if case .key(let code, false) = event { return code }
            return nil
        })
        #expect(released == [49, 13, 2])
        #expect(up.contains(.mouseButton(.left, down: false)))
        var drift = PadState()
        drift.rightStick = CGPoint(x: 0.05, y: 0.05)
        drift.leftStick = CGPoint(x: 0.3, y: 0)
        #expect(KeyboardPlay.events(from: .idle, to: drift).isEmpty)
    }

    @Test("Only while the game is frontmost: away from it nothing is posted until it is in front again")
    func onlyFrontmost() {
        let pad = FakePad(), poster = RecordingInputPoster(), focus = FakeFocus()
        let bridge = KeyboardPlayBridge(reader: pad, poster: poster, focus: focus)
        focus.front = Self.game.id
        pad.state = PadState(pressed: [], leftStick: CGPoint(x: 0, y: 1))
        bridge.tick(Self.game)
        #expect(poster.posted == [.key(13, down: true)])

        // The user switches to another app and keeps playing with the controller
        focus.front = "com.apple.Safari"
        bridge.tick(Self.game)
        #expect(poster.posted.last == .key(13, down: false), "the held key goes up on the way out")
        let before = poster.posted.count
        for step in 0..<30 {
            pad.state = PadState(pressed: step % 2 == 0 ? [.south, .rightTrigger] : [.east],
                                 leftStick: CGPoint(x: 1, y: 0), rightStick: CGPoint(x: 1, y: 1))
            bridge.tick(Self.game)
        }
        #expect(poster.posted.count == before, "posted while another app was in front")

        // Back to the game: what the controller holds now is pressed
        focus.front = Self.game.id
        pad.state = PadState(pressed: [.south], leftStick: CGPoint(x: 0, y: 1))
        bridge.tick(Self.game)
        #expect(Array(poster.posted.dropFirst(before)) == [.key(13, down: true), .key(49, down: true)])
    }

    @Test("Losing focus releases the held keys and mouse buttons; so does reset")
    func releasesHeldInput() {
        let pad = FakePad(), poster = RecordingInputPoster(), focus = FakeFocus()
        let bridge = KeyboardPlayBridge(reader: pad, poster: poster, focus: focus)
        focus.front = Self.game.id
        pad.state = PadState(pressed: [.south, .rightTrigger], leftStick: CGPoint(x: 0, y: 1))
        bridge.tick(Self.game)
        #expect(poster.posted.contains(.key(13, down: true)))

        focus.front = nil
        bridge.tick(Self.game)
        #expect(poster.posted.contains(.key(13, down: false)))
        #expect(poster.posted.contains(.key(49, down: false)))
        #expect(poster.posted.contains(.mouseButton(.left, down: false)))

        focus.front = Self.game.id
        bridge.tick(Self.game)
        let before = poster.posted.count
        bridge.reset()
        let released = poster.posted.dropFirst(before)
        #expect(released.contains(.key(13, down: false)))
        #expect(released.contains(.key(49, down: false)))
        #expect(released.contains(.mouseButton(.left, down: false)))
    }

    @Test("A keyDown rewritten before a focus change still rewrites its keyUp")
    func rewrittenKeyUpFollows() {
        let shared = LiveKeyTap.Shared()
        shared.table = [49: 14]
        #expect(shared.rewrite(49, up: false) == 14)
        shared.table = [:]
        #expect(shared.rewrite(49, up: true) == 14)
        #expect(shared.rewrite(49, up: true) == nil)
        #expect(shared.rewrite(36, up: true) == nil)
    }

    @Test("Another game in front counts as away")
    func otherGame() {
        let pad = FakePad(), poster = RecordingInputPoster(), focus = FakeFocus()
        let bridge = KeyboardPlayBridge(reader: pad, poster: poster, focus: focus)
        focus.front = "installer:other"
        pad.state = PadState(pressed: [.south])
        bridge.tick(Self.game)
        #expect(poster.posted.isEmpty)
    }

    @Test("A Wine game's process is told apart by its prefix, a Steam game by its app id")
    func processEnvironment() async throws {
        let installs = URL(filePath: "/tmp/cartouche-installs")
        let prefix = installs.appending(path: "hades/pfx").path(percentEncoded: false)
        // macOS hides the environment of its own binaries, not of others such as Wine's,
        // so the stand-in game is a program built here
        let work = try scratchDirectory("procargs")
        defer { try? FileManager.default.removeItem(at: work) }
        let source = work.appending(path: "game.c"), binary = work.appending(path: "game")
        try "#include <unistd.h>\nint main(void) { sleep(5); return 0; }\n".write(to: source, atomically: true, encoding: .utf8)
        let cc = Process()
        cc.executableURL = URL(filePath: "/usr/bin/cc")
        cc.arguments = [source.path, "-o", binary.path]
        try cc.run()
        cc.waitUntilExit()
        try #require(cc.terminationStatus == 0)
        let sleeper = Process()
        sleeper.executableURL = binary
        // An empty argument still counts in argv; it must not shift the environment
        sleeper.arguments = ["", "quiet"]
        sleeper.environment = ["WINEPREFIX": prefix, "SteamAppId": "1145360", "OTHER": "a=b"]
        try sleeper.run()
        defer { sleeper.terminate() }
        try await Task.sleep(for: .milliseconds(100))
        let environment = try #require(LiveGameFocus.environment(of: sleeper.processIdentifier))
        #expect(environment["WINEPREFIX"] == prefix)
        #expect(environment["OTHER"] == "a=b")
        #expect(LiveGameFocus.matches(Self.game, environment: environment, installs: installs))
        #expect(LiveGameFocus.matches(.steam(1_145_360, name: "Hades", installed: true), environment: environment, installs: installs))
        #expect(!LiveGameFocus.matches(.steam(620, name: "Portal 2", installed: true), environment: environment, installs: installs))
        let other = Game(id: "installer:celeste", source: .installer, name: "Celeste", installed: true)
        #expect(!LiveGameFocus.matches(other, environment: environment, installs: installs))
    }

    @Test("Remapped keys change only while the game is in front; modifiers are never remapped")
    func keyRemap() {
        let tap = FakeTap(), focus = FakeFocus()
        let remapper = KeyRemapper(tap: tap)
        let remaps = [KeyRemap(from: .space, to: .e), KeyRemap(from: .q, to: .q), KeyRemap(from: .command, to: .control)]
        focus.front = Self.game.id
        #expect(remapper.tick(Self.game, remaps: remaps))
        #expect(tap.table == [49: 14])
        remapper.stop()
        #expect(tap.stops == 1)
    }

    @Test("A tap macOS refuses is reported once and not retried at every poll")
    func refusedTap() {
        let tap = FakeTap()
        tap.refuses = true
        let remapper = KeyRemapper(tap: tap)
        #expect(!remapper.tick(Self.game, remaps: [KeyRemap(from: .a, to: .b)]))
        #expect(!remapper.tick(Self.game, remaps: [KeyRemap(from: .a, to: .b)]))
        #expect(tap.starts == 1)
        remapper.stop()
        tap.refuses = false
        #expect(remapper.tick(Self.game, remaps: [KeyRemap(from: .a, to: .b)]))
    }
}
