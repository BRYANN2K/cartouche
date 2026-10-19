// Play with a controller: for a game that only takes a keyboard and mouse,
// Cartouche reads the controller and posts key and mouse events. Posting needs
// Accessibility, and happens only while that game is the frontmost app.

import AppKit
import CoreGraphics
import Darwin
import Foundation

enum InputEvent: Equatable, Sendable {
    case key(CGKeyCode, down: Bool)
    case mouseButton(CGMouseButton, down: Bool)
    case mouseMove(dx: Double, dy: Double)
}

// The fixed layout: left stick to WASD, right stick to the mouse, buttons to keys
enum KeyboardPlay {

    // macOS virtual key codes (HIToolbox Events.h)
    static let keys: [PadButton: CGKeyCode] = [
        .south: 49,          // Space
        .east: 53,           // Escape
        .west: 14,           // E
        .north: 3,           // F
        .leftShoulder: 12,   // Q
        .rightShoulder: 15,  // R
        .leftStick: 56,      // Shift
        .rightStick: 59,     // Control
        .back: 48,           // Tab
        .start: 36,          // Return
        .up: 126, .down: 125, .left: 123, .right: 124,
    ]
    static let mouse: [PadButton: CGMouseButton] = [.rightTrigger: .left, .leftTrigger: .right]

    // W, A, S, D for the left stick past this point
    static let stickThreshold = 0.5
    static let deadZone = 0.15
    // Pointer points per poll at full tilt
    static let mouseSpeed = 14.0

    static func wasd(_ stick: CGPoint) -> Set<CGKeyCode> {
        var keys: Set<CGKeyCode> = []
        if stick.y > stickThreshold { keys.insert(13) }   // W
        if stick.y < -stickThreshold { keys.insert(1) }   // S
        if stick.x < -stickThreshold { keys.insert(0) }   // A
        if stick.x > stickThreshold { keys.insert(2) }    // D
        return keys
    }

    static func heldKeys(_ state: PadState) -> Set<CGKeyCode> {
        Set(state.pressed.compactMap { keys[$0] }).union(wasd(state.leftStick))
    }

    // What to post to go from what the game was last told to what the controller holds
    static func events(from old: PadState, to new: PadState) -> [InputEvent] {
        var out: [InputEvent] = []
        let before = heldKeys(old), after = heldKeys(new)
        out += after.subtracting(before).sorted().map { .key($0, down: true) }
        out += before.subtracting(after).sorted().map { .key($0, down: false) }
        for (button, mouseButton) in mouse.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            let was = old.pressed.contains(button), now = new.pressed.contains(button)
            if was != now { out.append(.mouseButton(mouseButton, down: now)) }
        }
        let stick = new.rightStick
        if hypot(stick.x, stick.y) > deadZone {
            // Screen y grows downward
            out.append(.mouseMove(dx: stick.x * mouseSpeed, dy: -stick.y * mouseSpeed))
        }
        return out
    }
}

@MainActor
protocol InputPoster: AnyObject {
    func post(_ events: [InputEvent])
}

// Posts into the session as if the keyboard and mouse were used
@MainActor
final class LiveInputPoster: InputPoster {
    private let source = CGEventSource(stateID: .hidSystemState)
    private var buttons: Set<CGMouseButton.RawValue> = []

    func post(_ events: [InputEvent]) {
        for event in events {
            switch event {
            case .key(let code, let down):
                CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)?.post(tap: .cghidEventTap)
            case .mouseButton(let button, let down):
                let type: CGEventType = button == .left ? (down ? .leftMouseDown : .leftMouseUp) : (down ? .rightMouseDown : .rightMouseUp)
                if down { buttons.insert(button.rawValue) } else { buttons.remove(button.rawValue) }
                CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: location, mouseButton: button)?
                    .post(tap: .cghidEventTap)
            case .mouseMove(let dx, let dy):
                let at = location
                let to = CGPoint(x: at.x + dx, y: at.y + dy)
                let type: CGEventType = buttons.contains(CGMouseButton.left.rawValue) ? .leftMouseDragged
                    : buttons.contains(CGMouseButton.right.rawValue) ? .rightMouseDragged : .mouseMoved
                let move = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: to, mouseButton: .left)
                // Games that hold the pointer read the deltas, not the position
                move?.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx.rounded()))
                move?.setIntegerValueField(.mouseEventDeltaY, value: Int64(dy.rounded()))
                move?.post(tap: .cghidEventTap)
            }
        }
    }

    private var location: CGPoint { CGEvent(source: nil)?.location ?? .zero }
}

// Whether a game is the frontmost app
@MainActor
protocol GameFocus: AnyObject {
    func isFrontmost(_ game: Game) -> Bool
}

// A Wine game's process says which game it is in its environment: WINEPREFIX for a
// game Cartouche installed, SteamAppId for a Steam game
@MainActor
final class LiveGameFocus: GameFocus {
    var installs: URL = GameFolder.installs
    private var cache: (pid: pid_t, environment: [String: String])?

    func isFrontmost(_ game: Game) -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return false }
        let pid = app.processIdentifier
        if cache?.pid != pid { cache = (pid, Self.environment(of: pid) ?? [:]) }
        return Self.matches(game, environment: cache?.environment ?? [:], installs: installs)
    }

    static func matches(_ game: Game, environment: [String: String], installs: URL) -> Bool {
        if let appID = game.steamAppID, game.source == .steam {
            return [environment["SteamAppId"], environment["STEAM_COMPAT_APP_ID"]].contains(String(appID))
        }
        guard game.id.hasPrefix("installer:"), let prefix = environment["WINEPREFIX"] else { return false }
        let folder = installs.appending(path: String(game.id.dropFirst("installer:".count))).appending(path: "pfx")
        return URL(filePath: prefix).standardizedFileURL.path == folder.standardizedFileURL.path
    }

    // KERN_PROCARGS2: argc, the executable path, argv, then the environment, all
    // NUL-separated. Only a process of the same user can be read.
    static func environment(of pid: pid_t) -> [String: String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var i = MemoryLayout<Int32>.size
        func nulTerminated() -> String? {
            guard i < size, let nul = buffer[i..<size].firstIndex(of: 0) else { return nil }
            defer { i = nul + 1 }
            return String(decoding: buffer[i..<nul], as: UTF8.self)
        }
        // The executable path, NUL padding, argc arguments (empty ones count),
        // padding, then the environment
        guard nulTerminated() != nil else { return nil }
        while i < size, buffer[i] == 0 { i += 1 }
        for _ in 0..<argc {
            guard nulTerminated() != nil else { return nil }
        }
        while i < size, buffer[i] == 0 { i += 1 }
        var environment: [String: String] = [:]
        while let entry = nulTerminated() {
            guard let equals = entry.firstIndex(of: "=") else { continue }
            environment[String(entry[..<equals])] = String(entry[entry.index(after: equals)...])
        }
        return environment
    }
}

// Runs the fixed layout for one game at a time, only while that game is in front
@MainActor
final class KeyboardPlayBridge {

    let reader: any PadReader
    let poster: any InputPoster
    let focus: any GameFocus
    // What the game holds as far as it was told
    private(set) var posted = PadState.idle

    init(reader: any PadReader, poster: any InputPoster, focus: any GameFocus) {
        self.reader = reader
        self.poster = poster
        self.focus = focus
    }

    // One poll. Away from the game nothing is posted; back in front, what the
    // controller holds is pressed again.
    func tick(_ game: Game) {
        guard focus.isFrontmost(game) else {
            release()
            return
        }
        let now = reader.read() ?? .idle
        let events = KeyboardPlay.events(from: posted, to: now)
        posted = now
        if !events.isEmpty { poster.post(events) }
    }

    func reset() { release() }

    // Clearing `posted` alone would leave the .hidSystemState source holding
    // keys and mouse buttons down: tell the game they are up first
    private func release() {
        let events = KeyboardPlay.events(from: posted, to: .idle)
        posted = .idle
        if !events.isEmpty { poster.post(events) }
    }
}
