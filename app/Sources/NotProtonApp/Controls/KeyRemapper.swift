// Remap keys for this game: while the game is in front, a key the user picked
// reaches it as another key. Cartouche reads the keyboard through an event tap,
// which needs Input Monitoring; macOS applies that permission after a relaunch.

import CoreGraphics
import Foundation

// The keyboard side: rewrites key codes in place while the table is set
@MainActor
protocol KeyTapping: AnyObject {
    var table: [CGKeyCode: CGKeyCode] { get set }
    // false when macOS refused the tap
    func start() -> Bool
    func stop()
}

final class LiveKeyTap: KeyTapping {

    // Read by the tap's callback on the main run loop
    final class Shared: @unchecked Sendable {
        var table: [CGKeyCode: CGKeyCode] = [:]
        // Each rewritten keyDown's target, so its keyUp matches even if the
        // table was cleared after a focus change
        var held: [CGKeyCode: CGKeyCode] = [:]
        var port: CFMachPort?

        func rewrite(_ code: CGKeyCode, up: Bool) -> CGKeyCode? {
            if up { return held.removeValue(forKey: code) }
            guard let to = table[code] else { return nil }
            held[code] = to
            return to
        }
    }

    private let shared = Shared()
    private var source: CFRunLoopSource?

    var table: [CGKeyCode: CGKeyCode] {
        get { shared.table }
        set { shared.table = newValue }
    }

    // Only called once Input Monitoring is allowed, so it cannot show a prompt
    func start() -> Bool {
        guard shared.port == nil else { return true }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, info in
                guard let info else { return Unmanaged.passUnretained(event) }
                let shared = Unmanaged<Shared>.fromOpaque(info).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let port = shared.port { CGEvent.tapEnable(tap: port, enable: true) }
                    return Unmanaged.passUnretained(event)
                }
                let code = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
                if let to = shared.rewrite(code, up: type == .keyUp) {
                    event.setIntegerValueField(.keyboardEventKeycode, value: Int64(to))
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(shared).toOpaque())
        else { return false }
        shared.port = port
        source = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        return true
    }

    func stop() {
        if let port = shared.port { CGEvent.tapEnable(tap: port, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        shared.port = nil
        shared.table = [:]
        shared.held = [:]
        source = nil
    }
}

// The tap runs only while the remapped game is in front; elsewhere every key
// stays itself
@MainActor
final class KeyRemapper {

    let tap: any KeyTapping
    private(set) var running = false
    // macOS refused the tap; tried again only after a stop
    private var refused = false

    init(tap: any KeyTapping) {
        self.tap = tap
    }

    // false when the tap could not start
    @discardableResult
    func tick(_ game: Game, remaps: [KeyRemap]) -> Bool {
        if !running {
            guard !refused, tap.start() else {
                refused = true
                return false
            }
            running = true
        }
        tap.table = KeyRemap.table(remaps)
        return true
    }

    func stop() {
        refused = false
        guard running else { return }
        tap.stop()
        running = false
    }
}
