import AppKit
import Carbon.HIToolbox

// A key and Carbon modifiers, stored under overlay.hotkey
struct HotkeyCombo: Codable, Equatable, Hashable, Sendable {
    var keyCode: UInt32
    var modifiers: UInt32

    static let optionC = HotkeyCombo(keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(optionKey))
    // The HUD level shortcut
    static let optionShiftC = HotkeyCombo(keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(optionKey | shiftKey))
    // ⌥⌘R opens Apps en arrière-plan
    static let resources = HotkeyCombo(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(optionKey | cmdKey))
    // ⌃⌘Q locks the screen, ⌥⌘Esc force-quits: macOS keeps both
    static let lockScreen = HotkeyCombo(keyCode: UInt32(kVK_ANSI_Q), modifiers: UInt32(controlKey | cmdKey))
    static let forceQuit = HotkeyCombo(keyCode: UInt32(kVK_Escape), modifiers: UInt32(optionKey | cmdKey))

    // Refused at recording: ⌘ without ⌥ or ⌃ is macOS's own (⌘Q, ⌘C, ⌘Space), ⌃⌘Q and ⌥⌘Esc too; ⌥⌘R is taken
    var reserved: Bool {
        (modifiers & UInt32(cmdKey) != 0 && modifiers & UInt32(optionKey | controlKey) == 0)
            || self == .resources || self == .lockScreen || self == .forceQuit
    }

    static let keyNames: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7",
        kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12", kVK_Space: "Space",
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E", kVK_ANSI_F: "F",
        kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
        kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R",
        kVK_ANSI_S: "S", kVK_ANSI_T: "T", kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
        kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z", kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
        kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
    ]

    var label: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + (Self.keyNames[Int(keyCode)] ?? "#\(keyCode)")
    }

    // A recorded key press; a combination needs at least one of ⌃⌥⌘
    init?(event: NSEvent) {
        var mods: UInt32 = 0
        if event.modifierFlags.contains(.control) { mods |= UInt32(controlKey) }
        if event.modifierFlags.contains(.option) { mods |= UInt32(optionKey) }
        if event.modifierFlags.contains(.shift) { mods |= UInt32(shiftKey) }
        if event.modifierFlags.contains(.command) { mods |= UInt32(cmdKey) }
        guard mods & UInt32(controlKey | optionKey | cmdKey) != 0, Self.keyNames[Int(event.keyCode)] != nil else { return nil }
        self.init(keyCode: UInt32(event.keyCode), modifiers: mods)
    }

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

@MainActor
protocol HotkeyRegistrar: AnyObject {
    func register(_ combo: HotkeyCombo, id: UInt32) -> Bool
    func unregisterAll()
    // The last refusal's status, for the log
    var lastStatus: OSStatus { get }
}

extension HotkeyRegistrar {
    var lastStatus: OSStatus { 0 }
}

@MainActor
enum OverlayHotkey {
    static let key = "overlay.hotkey"
    static let menuID: UInt32 = 1
    static let hudID: UInt32 = 2

    static let hudKey = "overlay.hotkey.hud"

    static func stored(_ defaults: UserDefaults = .standard, key: String = key) -> HotkeyCombo? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(HotkeyCombo.self, from: $0) }
            .flatMap { $0.reserved ? nil : $0 }
    }

    static func store(_ combo: HotkeyCombo?, _ defaults: UserDefaults = .standard, key: String = key) {
        if let combo, let data = try? JSONEncoder().encode(combo) { defaults.set(data, forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    static func hud(_ defaults: UserDefaults = .standard) -> HotkeyCombo {
        let hud = stored(defaults, key: hudKey) ?? .optionShiftC
        guard hud != (stored(defaults) ?? .optionC) else { return hud == .optionShiftC ? .optionC : .optionShiftC }
        return hud
    }

    // Why a recorded combination cannot be kept; nil when it can
    static func refusal(of combo: HotkeyCombo, other: HotkeyCombo) -> String? {
        combo.reserved || combo == other ? ot("This shortcut is already taken") : nil
    }

    // A "Default" press answers like a recorded press: refused when it would double the other line
    static func refusal(ofDefault fallback: HotkeyCombo, other: HotkeyCombo) -> String? {
        refusal(of: fallback, other: other)
    }

    // Registered only while a game Cartouche launched runs, so ⌥C types « ç » the rest of the time.
    // No fallback: when the menu's shortcut is taken the log says so, and the menu stays reachable
    // from the status menu. Returns the menu's combination.
    static func register(stored: HotkeyCombo?, hud: HotkeyCombo = .optionShiftC, with registrar: HotkeyRegistrar,
                         log: (String) -> Void = AppLog.note) -> HotkeyCombo? {
        registrar.unregisterAll()
        let wanted = (stored?.reserved == true ? nil : stored) ?? .optionC
        let menu = registrar.register(wanted, id: menuID) ? wanted : nil
        log(menu != nil ? "hotkey: registered \(wanted.label)"
            : "hotkey: failed \(wanted.label), \(reason(registrar.lastStatus)); the menu opens from the status menu")
        if hud != wanted && !hud.reserved {
            log(registrar.register(hud, id: hudID) ? "hotkey: registered \(hud.label) (HUD)"
                : "hotkey: failed \(hud.label) (HUD), \(reason(registrar.lastStatus))")
        }
        return menu
    }

    static func reason(_ status: OSStatus) -> String {
        switch Int(status) {
        case eventHotKeyExistsErr: "taken by another app or another Cartouche (status \(status))"
        case eventHotKeyInvalidErr: "not a valid combination (status \(status))"
        default: "status \(status)"
        }
    }

    // Two Cartouche running: the shortcut belongs to the one that launched the game
    static func othersNote(_ others: [(pid: pid_t, path: String)]) -> String? {
        guard !others.isEmpty else { return nil }
        let list = others.map { "pid \($0.pid), \($0.path)" }.joined(separator: "; ")
        return "hotkey: another Cartouche is running (\(list)); only the one that launched the game registers the shortcut"
    }

    static func otherInstances() -> [(pid: pid_t, path: String)] {
        let me = getpid(), id = Bundle.main.bundleIdentifier
        return NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.processIdentifier != me,
                  (id != nil && app.bundleIdentifier == id) || app.executableURL?.lastPathComponent == "Cartouche" else { return nil }
            return (app.processIdentifier, app.bundleURL?.path(percentEncoded: false) ?? app.executableURL?.path(percentEncoded: false) ?? "?")
        }
    }
}

// Carbon's RegisterEventHotKey: no permission, the key is swallowed (spike S3)
@MainActor
final class CarbonHotkeys: HotkeyRegistrar {
    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private(set) var lastStatus: OSStatus = 0
    var fired: (UInt32) -> Void = { _ in }

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard let context else { return noErr }
            let keys = Unmanaged<CarbonHotkeys>.fromOpaque(context).takeUnretainedValue()
            let which = id.id
            MainActor.assumeIsolated { keys.fired(which) }
            return noErr
        }, 1, &spec, me, &handler)
    }

    func register(_ combo: HotkeyCombo, id: UInt32) -> Bool {
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, EventHotKeyID(signature: OSType(0x43415254), id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { lastStatus = status == noErr ? OSStatus(eventHotKeyInvalidErr) : status; return false }
        refs.append(ref)
        return true
    }

    func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
    }
}
