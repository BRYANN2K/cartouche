import SwiftUI

struct ControlsRow: View {
    let game: Game
    let center: ControlsCenter

    var body: some View {
        let handler = ControlsHandler(game)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "gamecontroller")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    if let pad = center.monitor.primary {
                        Text(verbatim: pad.shortName).fontWeight(.semibold)
                        Text(pad.status).font(.callout).foregroundStyle(.secondary)
                    } else {
                        Text("No controller").fontWeight(.semibold)
                        Text("Keyboard and mouse").font(.callout).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(verbatim: handler.title).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            Divider()
            HStack {
                Text(handler.hint).font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Customize…") { center.present(game) }.controlSize(.small)
            }
        }
        .onAppear { center.monitor.batteryShown(true) }
        .onDisappear { center.monitor.batteryShown(false) }
    }
}

extension View {
    func controlsSheet(_ center: ControlsCenter) -> some View {
        sheet(item: Binding(get: { center.presented }, set: { if $0 == nil { center.dismiss() } })) { game in
            if let session = center.session, session.game.id == game.id {
                ControlsSheet(center: center, session: session)
            }
        }
    }

    func couchRing(_ on: Bool, radius: CGFloat = 8) -> some View {
        overlay {
            if on {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(-4)
                    .allowsHitTesting(false)
            }
        }
    }
}

struct ControlsSheet: View {

    enum Tab: Hashable { case controller, keyboard }

    let center: ControlsCenter
    let session: ControlsSession
    @State private var tab: Tab

    init(center: ControlsCenter, session: ControlsSession) {
        self.center = center
        self.session = session
        _tab = State(initialValue: session.opensOnKeyboard || session.remap.phase == .waitingForRelaunch ? .keyboard : .controller)
    }

    private var game: Game { session.game }
    private var handler: ControlsHandler { ControlsHandler(game) }
    private var controls: GameControls { center.controls(for: game) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Controls for \(game.name)").font(.title2.weight(.bold))
                .padding([.horizontal, .top], 22)
            if let relaunch = center.relaunch, let route = center.route {
                RelaunchBanner(service: relaunch, route: route).padding(.horizontal, 22)
            }
            if handler != .retroArch {
                Picker("Controls", selection: $tab) {
                    Text("Controller").tag(Tab.controller)
                    Text("Keyboard and Mouse").tag(Tab.keyboard)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .padding(.horizontal, 22)
            }
            Form {
                if tab == .controller || handler == .retroArch {
                    controllerTab
                } else {
                    keyboardTab
                }
            }
            .formStyle(.grouped)
            if let problem = center.problem {
                Text(problem).font(.callout).foregroundStyle(.red).padding(.horizontal, 22)
            }
            HStack {
                Spacer()
                Button("Done") { center.dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding([.horizontal, .bottom], 22)
        }
        .frame(width: 560, height: 620)
        .onChange(of: session.remap.isOn) { _, on in Task { await center.update(game) { $0.remapKeys = on } } }
        .onChange(of: session.play.isOn) { _, on in Task { await center.update(game) { $0.playWithController = on } } }
    }

    // MARK: Controller

    @ViewBuilder
    private var controllerTab: some View {
        if handler == .steamInput {
            Section {
                LabeledContent {
                    Button("Open in Steam") { center.openInSteam(game) }
                } label: {
                    Text("Steam Input handles this game")
                    Text("Layouts, gyro and community configurations live in Steam.")
                }
            }
        } else {
            Section {
                Picker("Layout", selection: Binding<ControllerLayout.Preset?>(
                    get: { controls.layout.preset },
                    set: { preset in
                        guard let preset else { return }
                        Task { await center.update(game) { $0.layout = .preset(preset) } }
                    }
                )) {
                    ForEach(presets) { Text($0.title).tag(Optional($0)) }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text(handler == .retroArch
                     ? "Saved as a RetroArch remap file for this game. Changes apply at the next launch."
                     : "The game sees an Xbox controller. Changes apply at the next launch.")
            }
            Section {
                ForEach(PadButton.allCases) { button in
                    Picker(selection: Binding(
                        get: { controls.layout.target(of: button) },
                        set: { target in Task { await center.update(game) { $0.layout.set(button, sends: target) } } }
                    )) {
                        ForEach(PadButton.allCases) { Text(verbatim: targetLabel($0)).tag($0) }
                    } label: {
                        Text(verbatim: button.label(family))
                    }
                }
            } header: {
                Text("Each button sends")
            }
        }
    }

    private var presets: [ControllerLayout.Preset] {
        handler == .retroArch ? [.standard, .swapAB] : [.standard, .southpaw]
    }

    private var family: PadFamily { center.monitor.primary?.family ?? .playStation }

    private func targetLabel(_ button: PadButton) -> String {
        handler == .retroArch ? button.retroPad : button.xbox
    }

    // MARK: Keyboard and mouse

    @ViewBuilder
    private var keyboardTab: some View {
        Section {
            toggle(String(localized: "Command acts as Control"), String(localized: "Copy, paste and shortcuts work like on Windows"),
                   \.commandAsControl)
            toggle(String(localized: "Option acts as Alt"), nil, \.optionAsAlt)
            toggle(String(localized: "Keep the mouse inside the game"),
                   String(localized: "When the game holds the pointer, as shooters and strategy games do"), \.keepMouseInside)
            toggle(String(localized: "Precise scrolling"), nil, \.preciseScrolling)
        } footer: {
            Text("Applied to the game’s Wine prefix at the next launch.")
        }
        Section {
            GatedOptionRow(option: session.remap, title: String(localized: "Remap keys for this game"),
                           subtitle: String(localized: "Change what keys do in \(game.name)"))
            if session.remap.isOn { keyRemapRows }
        }
        Section {
            GatedOptionRow(option: session.play, title: String(localized: "Play with a controller"),
                           subtitle: String(localized: "For games that only take a keyboard: left stick to WASD, right stick to the mouse, buttons to keys"))
        } footer: {
            Text("Needs Accessibility access for Cartouche, asked once.")
        }
    }

    private func toggle(_ title: String, _ subtitle: String?, _ key: WritableKeyPath<KeyboardOptions, Bool>) -> some View {
        Toggle(isOn: Binding(
            get: { controls.keyboard[keyPath: key] },
            set: { on in Task { await center.update(game) { $0.keyboard[keyPath: key] = on; $0.keyboardSet = true } } }
        )) {
            Text(title)
            if let subtitle { Text(subtitle) }
        }
        .toggleStyle(.switch)
    }

    @ViewBuilder
    private var keyRemapRows: some View {
        ForEach(controls.keyRemaps.indices, id: \.self) { index in
            HStack {
                keyPicker(String(localized: "Key"), index: index, from: true)
                Image(systemName: "arrow.right").foregroundStyle(.secondary).accessibilityHidden(true)
                keyPicker(String(localized: "Becomes"), index: index, from: false)
                Spacer()
                Button {
                    Task { await center.update(game) { if $0.keyRemaps.indices.contains(index) { $0.keyRemaps.remove(at: index) } } }
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text("Remove"))
            }
        }
        Button("Add Key") {
            Task { await center.update(game) { $0.keyRemaps.append(KeyRemap(from: .space, to: .space)) } }
        }
    }

    private func keyPicker(_ title: String, index: Int, from: Bool) -> some View {
        Picker(title, selection: Binding(
            get: {
                let remap = controls.keyRemaps.indices.contains(index) ? controls.keyRemaps[index] : KeyRemap(from: .space, to: .space)
                return from ? remap.from : remap.to
            },
            set: { key in edit(index) { if from { $0.from = key } else { $0.to = key } } }
        )) {
            ForEach(MacKey.allCases.filter { !$0.isModifier }) { Text(verbatim: $0.label).tag($0) }
        }
        .labelsHidden()
        .frame(width: 110)
    }

    private func edit(_ index: Int, _ change: @escaping (inout KeyRemap) -> Void) {
        Task {
            await center.update(game) { controls in
                guard controls.keyRemaps.indices.contains(index) else { return }
                change(&controls.keyRemaps[index])
            }
        }
    }
}

struct ControllersSettingsView: View {
    let center: ControlsCenter

    var body: some View {
        @Bindable var couch = center.couch
        Form {
            Section {
                if center.monitor.controllers.isEmpty {
                    LabeledContent {
                        EmptyView()
                    } label: {
                        Text("No controller connected")
                        Text("Pair one in System Settings > Bluetooth, or plug it in.").foregroundStyle(.secondary)
                    }
                }
                ForEach(center.monitor.controllers) { pad in
                    LabeledContent {
                        Text(verbatim: pad.batteryText ?? "").foregroundStyle(.secondary).monospacedDigit()
                    } label: {
                        Text(verbatim: pad.name)
                        Text(pad.status).foregroundStyle(.secondary)
                    }
                }
                LabeledContent {
                    EmptyView()
                } label: {
                    Text("Keyboard and trackpad")
                    Text("Built in").foregroundStyle(.secondary)
                }
            }
            Section {
                Toggle(isOn: $couch.isOn) {
                    Text("Couch mode")
                    Text("Move around Cartouche with the controller: the D-pad picks a game, A opens it and plays, B goes back, L1 and R1 change the list.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { center.monitor.batteryShown(true) }
        .onDisappear { center.monitor.batteryShown(false) }
    }
}
