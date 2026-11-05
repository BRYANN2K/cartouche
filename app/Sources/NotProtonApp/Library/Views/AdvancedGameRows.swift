import SwiftUI

// Avancé, folded: Image and En jeu read and write the game's one profile, the in-game menu's;
// Compatibilité keeps the Wine options. Same words as the menu, no notes.
struct AdvancedGameRows: View {
    let game: Game
    @Bindable var model: LibraryModel
    var running = false
    var antiCheat: String?

    @State private var expanded = false
    @State private var changedWhilePlaying: Set<String> = []
    @State private var confirmingSharpening = false
    @Environment(\.openSettings) private var openSettings
    @Environment(\.advancedOpen) private var startsOpen

    private var resolved: GameSetup { model.resolution(for: game).setup }

    private var windows: Bool { resolved.version == .windows }

    private var supported: Set<AdvancedOption> {
        let setup = resolved
        guard setup.version == .windows else { return [] }
        return AdvancedSupport.options(runner: setup.runner, backend: setup.backend,
                                       translation: setup.translation, availability: model.backendAvailability)
    }

    private var dlss: Bool { supported.contains(.dlss) && model.shipsDLSS(game) }
    private var profile: OverlaySettings { model.profile(for: game.id).fitted(dlss: dlss) }
    private var access: UpscaleAccess { UpscaleAccess(dlss: dlss, sharpening: profile.allowsOurCode(protected: antiCheat != nil)) }
    // Under an anti-cheat, without consent
    private var locked: Bool { antiCheat != nil && !access.sharpening }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.spring(duration: 0.26, bounce: 0)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text("Advanced")
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Glass.label2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .accessibilityAddTraits(.isHeader)
            .accessibilityValue(expanded ? Text("Expanded") : Text("Collapsed"))
            if expanded {
                VStack(alignment: .leading, spacing: 0) {
                    if windows { image }
                    inGame
                    if windows && !compatibility.isEmpty { compat }
                }
                .transition(.opacity)
            }
        }
        .padding(.bottom, 18)
        .onAppear { if startsOpen { expanded = true } }
        .onChange(of: running) { if !running { changedWhilePlaying = [] } }
    }

    // MARK: Image

    // The segment shows what runs; a mode the game may not run stays stored for when it may
    private var image: some View {
        let access = access
        let scaling = access.scales(profile.upscale)
        return section(Text(ot("Image")), lock: locked, help: locked ? AntiCheatRow.reason : nil) {
            row(Text(ot("Cartouche Engine")), changed: "sharpening") {
                Toggle(isOn: Binding(get: { access.sharpening }, set: setSharpening)) { Text(ot("Cartouche Engine")) }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .id(confirmingSharpening)
            }
            divider
            VStack(alignment: .leading, spacing: 8) {
                Text(ot("Upscaling")).font(.system(size: 13))
                PageSegmented(title: ot("Upscaling"), options: [
                    .init(value: UpscaleMode.off, title: ot("Off")),
                    .init(value: .spatial, title: ot("Cartouche"), disabled: !access.sharpening,
                          help: access.sharpening ? nil : ot("Needs Cartouche Engine")),
                    .init(value: .temporal, title: ot("DLSS"), disabled: !dlss, help: dlss ? nil : ot("This game has no DLSS")),
                ], selection: Binding(get: { access.effective(profile.upscale) }, set: { mode in
                    guard access.allows(mode) else { return }
                    update("upscale") { $0.upscale = mode }
                }))
            }
            .rowPadding()
            divider
            row(Text(ot("Render Scale")), changed: "renderScale", enabled: scaling) {
                slider(\.renderScale, in: 50...100, step: 1, key: "renderScale", enabled: scaling) { OverlayFormat.percent(Double($0)) }
            }
            divider
            row(Text(ot("Sharpness")), changed: "sharpness", enabled: scaling) {
                slider(\.sharpness, in: 0...100, step: 5, key: "sharpness", enabled: scaling) {
                    OverlayFormat.decimal(Double($0) / 100, digits: 2)
                }
            }
            divider
            row(Text(ot("Generated Frames")), changed: nil, enabled: access.sharpening) { PageSoonPill() }
        }
        .alert(SharpeningConsent.title(game: game.name), isPresented: $confirmingSharpening) {
            Button(ot("Cancel"), role: .cancel) {}
            Button(ot("Turn On")) { update("sharpening") { $0.sharpening = SharpeningConsent.stored(true, protected: true) } }
        } message: {
            Text(verbatim: SharpeningConsent.message(game: game.name, antiCheat: antiCheat ?? ""))
        }
    }

    private func setSharpening(_ on: Bool) {
        let protected = antiCheat != nil
        if SharpeningConsent.asks(on, protected: protected) { confirmingSharpening = true; return }
        update("sharpening") { $0.sharpening = SharpeningConsent.stored(on, protected: protected) }
    }

    // MARK: En jeu

    private var inGame: some View {
        section(Text(ot("In Game")), lock: false, help: nil) {
            VStack(alignment: .leading, spacing: 8) {
                Text(ot("HUD")).font(.system(size: 13))
                PageSegmented(title: ot("HUD"), options: [
                    .init(value: HUDLevel.hidden, title: ot("Hidden")), .init(value: .mini, title: ot("Mini")),
                    .init(value: .standard, title: ot("Standard")), .init(value: .full, title: ot("Full")),
                ], selection: binding(\.hud, "hud"))
            }
            .rowPadding()
            divider
            row(Text(ot("Corner")), changed: "corner") {
                PageCornerPicker(corner: binding(\.corner, "corner"))
            }
            divider
            row(Text(ot("Shortcuts")), changed: nil) {
                HStack(spacing: 6) {
                    PageKeyCap(OverlayHotkey.stored()?.label ?? HotkeyCombo.optionC.label)
                        .help(Text("In-Game Menu"))
                    PageKeyCap(OverlayHotkey.hud().label)
                        .help(Text(verbatim: "HUD"))
                    Button(ot("Edit…")) {
                        SettingsRoute.shared.tab = .inGameMenu
                        openSettings()
                    }
                    .buttonStyle(.pill)
                    .padding(.leading, 6)
                }
            }
        }
    }

    // MARK: Compatibilité

    private var compatibility: [AdvancedOption] {
        [.advertiseAVX, .msync, .highResolution, .metalHUD].filter(supported.contains)
    }

    private var compat: some View {
        section(Text(ot("Compatibility")), lock: false, help: nil) {
            ForEach(Array(compatibility.enumerated()), id: \.element) { index, option in
                if index > 0 { divider }
                switch option {
                case .advertiseAVX: toggle(Text("AVX2 to Rosetta"), key: "avx", \.advertiseAVX)
                case .msync: toggle(Text(verbatim: "MSync"), key: "msync", \.msync)
                case .highResolution: toggle(Text("High Resolution"), key: "hires", \.highResolution)
                default:
                    row(Text("Metal HUD"), changed: "metalHUD") {
                        Toggle(isOn: Binding(get: { !profile.hideMetalHUD }, set: { on in
                            update("metalHUD") { $0.hideMetalHUD = !on }
                        })) { Text("Metal HUD") }
                        .toggleStyle(.switch).labelsHidden().controlSize(.small)
                    }
                }
            }
        }
    }

    // MARK: Parts

    private func section<C: View>(_ title: Text, lock: Bool, help: String?, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                title
                if lock {
                    Image(systemName: "lock").accessibilityLabel(Text(ot("Locked by the anti-cheat")))
                }
            }
            .groupHeader()
            .contentShape(Rectangle())
            .help(help.map { Text(verbatim: $0) } ?? Text(verbatim: ""))
            .padding(.top, 12)
            VStack(alignment: .leading, spacing: 0, content: content)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .groupBackground(radius: Glass.panelRadius)
        }
    }

    private var divider: some View {
        Rectangle().fill(Glass.separator).frame(height: 1).padding(.horizontal, 12)
    }

    private func row<C: View>(_ title: Text, changed key: String?, enabled: Bool = true, @ViewBuilder _ control: () -> C) -> some View {
        HStack(spacing: 12) {
            title.font(.system(size: 13)).lineLimit(1).layoutPriority(1)
                .foregroundStyle(enabled ? Color.primary : Glass.label2)
            if let key, changedWhilePlaying.contains(key) { NextLaunchPill() }
            Spacer(minLength: 8)
            control()
        }
        .frame(minHeight: 44 - 16)
        .rowPadding()
    }

    private func toggle(_ title: Text, key: String, _ path: WritableKeyPath<AdvancedGameOptions, Bool>) -> some View {
        row(title, changed: key) {
            Toggle(isOn: Binding(get: { (model.setup(for: game.id).advanced ?? AdvancedGameOptions())[keyPath: path] }, set: { value in
                var setup = model.setup(for: game.id)
                var options = setup.advanced ?? AdvancedGameOptions()
                options[keyPath: path] = value
                setup.advanced = options
                model.setSetup(setup, for: game.id)
                if running { changedWhilePlaying.insert(key) }
            })) { title }
            .toggleStyle(.switch).labelsHidden().controlSize(.small)
        }
    }

    private func slider(_ path: WritableKeyPath<OverlaySettings, Int>, in range: ClosedRange<Double>, step: Double, key: String,
                        enabled: Bool = true, format: @escaping (Int) -> String) -> some View {
        HStack(spacing: 12) {
            Slider(value: Binding(get: { Double(profile[keyPath: path]) }, set: { value in
                update(key) { $0[keyPath: path] = Int((value / step).rounded() * step) }
            }), in: range)
            .labelsHidden()
            .frame(width: 88)
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.4)
            .saturation(enabled ? 1 : 0)
            Text(verbatim: format(profile[keyPath: path]))
                .font(.system(size: 13)).monospacedDigit().foregroundStyle(Glass.label2)
                .frame(minWidth: 40, alignment: .trailing)
        }
    }

    private func binding<T: Equatable>(_ path: WritableKeyPath<OverlaySettings, T>, _ key: String) -> Binding<T> {
        Binding(get: { profile[keyPath: path] }, set: { value in update(key) { $0[keyPath: path] = value } })
    }

    private func update(_ key: String, _ change: (inout OverlaySettings) -> Void) {
        var s = model.profile(for: game.id)
        change(&s)
        model.setProfile(s.fitted(dlss: dlss), for: game.id)
        if running { changedWhilePlaying.insert(key) }
    }
}

// Cartouche Sharpening, per game and revocable, never global. Under an anti-cheat, turning it on asks first
enum SharpeningConsent {
    static func asks(_ on: Bool, protected: Bool) -> Bool { on && protected }

    // The game's default is stored as nil
    static func stored(_ on: Bool, protected: Bool) -> Bool? { on == !protected ? nil : on }

    static func title(game: String) -> String { String(format: ot("Turn On Cartouche Engine for %@?"), game) }

    static func message(game: String, antiCheat: String) -> String {
        String(format: ot("%1$@ uses %2$@. Our code will load into the game: risk of a ban."), game, antiCheat)
    }
}

extension EnvironmentValues {
    // Snapshots open Avancé from the start
    @Entry var advancedOpen = false
    // Tests read where Play sits in the panel
    @Entry var playTop: ((CGFloat) -> Void)? = nil
}

private extension View {
    func rowPadding() -> some View { padding(.horizontal, 12).padding(.vertical, 8) }
}

// « Bientôt » in place of a control, as the menu shows it
struct PageSoonPill: View {
    var body: some View {
        Text(ot("Coming Soon"))
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Glass.label2)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Glass.fill2, in: .capsule)
    }
}

// A change made while the game runs reaches it at its next launch
struct NextLaunchPill: View {
    var body: some View {
        Text("Next launch")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.orange)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Color.orange.opacity(0.16), in: .capsule)
            .fixedSize()
    }
}

struct PageKeyCap: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 6)
            .frame(minHeight: 20)
            .background(Glass.fill2, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

// The HUD's corner as four tiles, the chosen one in accent
struct PageCornerPicker: View {
    @Binding var corner: HUDCorner

    var body: some View {
        Grid(horizontalSpacing: 3, verticalSpacing: 3) {
            GridRow { tile(.topLeft); tile(.topRight) }
            GridRow { tile(.bottomLeft); tile(.bottomRight) }
        }
        .padding(3)
        .background(Glass.fill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(ot("Corner")))
    }

    private func tile(_ value: HUDCorner) -> some View {
        Button { corner = value } label: {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(corner == value ? Color.accentColor : Glass.fill2)
                .frame(width: 22, height: 13)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(Self.name(value)))
        .accessibilityAddTraits(corner == value ? .isSelected : [])
    }

    static func name(_ corner: HUDCorner) -> String {
        switch corner {
        case .topLeft: ot("Top Left")
        case .topRight: ot("Top Right")
        case .bottomLeft: ot("Bottom Left")
        case .bottomRight: ot("Bottom Right")
        }
    }
}

// The mockup's segmented control: equal segments over the full width, a sliding pill, a segment may be off
struct PageSegmented<Value: Hashable>: View {
    struct Option {
        var value: Value
        var title: String
        var disabled = false
        var help: String?
    }

    let title: String
    let options: [Option]
    @Binding var selection: Value
    @Namespace private var pill
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.value) { option in
                let chosen = option.value == selection
                Button {
                    withAnimation(reduceMotion ? nil : .spring(duration: 0.28, bounce: 0)) { selection = option.value }
                } label: {
                    Text(verbatim: option.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(chosen ? Color.primary : Glass.label2)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, minHeight: 24)
                        .background {
                            if chosen {
                                Capsule()
                                    .fill(colorScheme == .dark ? Color.white.opacity(0.22) : Color.white)
                                    .shadow(color: .black.opacity(colorScheme == .dark ? 0.25 : 0.15), radius: 1.5, y: 1)
                                    .matchedGeometryEffect(id: "pill", in: pill)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(option.disabled)
                .opacity(option.disabled && isEnabled ? 0.4 : 1)
                .help(option.help.map { Text(verbatim: $0) } ?? Text(verbatim: ""))
                .accessibilityAddTraits(chosen ? [.isSelected] : [])
            }
        }
        .padding(2)
        .background(colorScheme == .dark ? Glass.fill : Color.black.opacity(0.06), in: Capsule())
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: title))
    }
}
