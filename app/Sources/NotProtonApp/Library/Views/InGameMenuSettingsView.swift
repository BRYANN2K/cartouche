import AppKit
import SwiftUI

// Settings › In-Game Menu: the two shortcuts, recorded by pressing them
struct InGameMenuSettingsView: View {
    @State private var menu = OverlayHotkey.stored() ?? .optionC
    @State private var hud = OverlayHotkey.hud()

    var body: some View {
        Form {
            Section {
                LabeledContent(ot("In-Game Menu")) {
                    ShortcutRecorder(combo: $menu, other: hud, fallback: .optionC) { OverlayHotkey.store($0) }
                }
                LabeledContent(ot("HUD")) {
                    ShortcutRecorder(combo: $hud, other: menu, fallback: .optionShiftC) { OverlayHotkey.store($0, key: OverlayHotkey.hudKey) }
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: menu) { OverlayController.shared.shortcutsChanged() }
        .onChange(of: hud) { OverlayController.shared.shortcutsChanged() }
    }
}

// Click, then press a combination with ⌃, ⌥ or ⌘; Escape gives up
struct ShortcutRecorder: View {
    @Binding var combo: HotkeyCombo
    let other: HotkeyCombo
    let fallback: HotkeyCombo
    let save: (HotkeyCombo?) -> Void
    @State private var recording = false
    @State private var monitor: Any?
    @State private var refused: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button {
                    recording ? stop() : start()
                } label: {
                    Text(recording ? ot("Press the new combination") : combo.label)
                        .font(.system(size: 13, weight: recording ? .regular : .medium))
                        .monospacedDigit()
                        .frame(minWidth: 120)
                }
                .buttonStyle(.bordered)
                if combo != fallback {
                    Button(ot("Default")) {
                        if let why = OverlayHotkey.refusal(ofDefault: fallback, other: other) {
                            refused = why
                        } else {
                            refused = nil
                            combo = fallback
                            save(nil)
                        }
                    }
                    .buttonStyle(.borderless)
                }
            }
            if let refused {
                Text(refused)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        refused = nil
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { stop(); return nil }
            guard let next = HotkeyCombo(event: event) else { return nil }
            if let why = OverlayHotkey.refusal(of: next, other: other) { refused = why; return nil }
            combo = next
            save(next == fallback ? nil : next)
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
