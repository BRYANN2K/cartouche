import Carbon.HIToolbox
import Testing
@testable import NotProtonApp

// app.log says whether ⌥C registered, why not, and when another Cartouche runs
@MainActor
@Suite("Hotkey log")
struct HotkeyLogTests {
    final class Refusing: HotkeyRegistrar {
        var refused: Set<HotkeyCombo> = []
        var lastStatus: OSStatus = 0
        func register(_ combo: HotkeyCombo, id: UInt32) -> Bool {
            guard refused.contains(combo) else { return true }
            lastStatus = OSStatus(eventHotKeyExistsErr)
            return false
        }
        func unregisterAll() {}
    }

    @Test("Registered: one line per shortcut")
    func registered() {
        var lines: [String] = []
        let menu = OverlayHotkey.register(stored: nil, with: Refusing(), log: { lines.append($0) })
        #expect(menu == .optionC)
        #expect(lines == ["hotkey: registered ⌥C", "hotkey: registered ⌥⇧C (HUD)"])
    }

    @Test("Refused: the combination and the reason")
    func refused() {
        var lines: [String] = []
        let keys = Refusing()
        keys.refused = [.optionC]
        #expect(OverlayHotkey.register(stored: nil, with: keys, log: { lines.append($0) }) == nil)
        #expect(lines.first == "hotkey: failed ⌥C, taken by another app or another Cartouche (status -9878); the menu opens from the status menu")
        #expect(lines.last == "hotkey: registered ⌥⇧C (HUD)")
    }

    @Test("Another Cartouche running is named in the log")
    func otherInstance() {
        #expect(OverlayHotkey.othersNote([]) == nil)
        #expect(OverlayHotkey.othersNote([(78993, "/Applications/Cartouche.app")])
                == "hotkey: another Cartouche is running (pid 78993, /Applications/Cartouche.app); only the one that launched the game registers the shortcut")
    }
}
