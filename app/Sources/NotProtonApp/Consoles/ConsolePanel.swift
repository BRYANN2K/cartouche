import AppKit
import GameController
import RetroArchKit
import SwiftUI

// The console modules under the shared panel chrome. The page itself lives in GamePanel.
struct ConsolePanel: View {
    let game: Game
    let console: ConsoleGame
    let content: ConsolePanelContent
    let center: ConsoleCenter
    @Bindable var model: LibraryModel
    let actions: GameActionRunner
    @Binding var showingMore: Bool
    @Binding var showingJoin: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(ControlsCenter.self) private var controls: ControlsCenter?

    var body: some View {
        ForEach(content.sections, id: \.self) { section in
            block(section, content)
        }
    }

    @ViewBuilder
    private func block(_ section: PanelModule, _ content: ConsolePanelContent) -> some View {
        switch section {
        case .play:
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Button {
                        Task { await center.play(console.id, resume: content.hasAutoState && content.statesAllowed, reduceMotion: reduceMotion) }
                    } label: {
                        Label(content.playLabel, systemImage: "play.fill")
                    }
                    .buttonStyle(PlayCapsuleStyle())
                    .couchRing(controls?.couch.ringsPlay == true, radius: 19)
                    .disabled(!content.canPlay)
                    Menu {
                        GameMenuContent(items: GameMenu.items(for: game, in: model, consoles: center)) { actions.perform($0, on: game) }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuStyle(.button)
                    .menuIndicator(.hidden)
                    .buttonStyle(RoundFillStyle())
                    .fixedSize()
                    .accessibilityLabel(Text("More"))
                }
                if let note = content.playNote {
                    Text(note).font(.system(size: 12))
                        .foregroundStyle(content.route.missingText == nil ? Glass.label2 : Color.orange)
                }
            }
            .padding(.bottom, 22)
        case .bios:
            if let warning = content.biosWarning {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(warning.title).font(.system(size: 13, weight: .semibold))
                        Text(warning.detail).font(.system(size: 12)).foregroundStyle(Glass.label2)
                        Button("Show BIOS Folder") {
                            try? FileManager.default.createDirectory(at: center.paths.bios, withIntermediateDirectories: true)
                            NSWorkspace.shared.open(center.paths.bios)
                        }
                        .buttonStyle(.pill)
                        .padding(.top, 2)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .groupBackground(tint: .orange)
                .accessibilityElement(children: .combine)
                .padding(.bottom, 18)
            }
        case .continueFrom:
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: section.title).groupHeader()
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(content.states) { state in
                            StateButton(state: state, look: console.setup.look, disabled: !content.canPlay || !content.statesAllowed) {
                                Task {
                                    await center.play(console.id, slot: state.slot, resume: state.isAuto, reduceMotion: reduceMotion)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 2)
                    .padding(.vertical, 4)
                }
            }
            .padding(.bottom, 18)
        case .yourPlay:
            group(section.title) {
                HStack(alignment: .top, spacing: 8) {
                    StatCell(title: Text("Played"), value: content.played)
                    StatCell(title: Text("Achievements"), value: content.achievements)
                }
            }
        case .expected, .antiCheat, .graphics, .advanced:
            EmptyView()
        case .setup:
            group(section.title) {
                EmulatorRows(console: content.console, route: content.route, center: center)
                if content.route == .retroArch { ConsoleSetupRows(game: console, content: content, center: center) }
            }
        case .controls:
            group(section.title) {
                if let controls { ControlsRow(game: game, center: controls) } else { ControllerRow() }
            }
        case .playTogether:
            group(section.title) {
                PlayTogetherRow(game: console, content: content, center: center, showingJoin: $showingJoin)
            }
        case .more:
            HStack {
                Text("Achievements, BIOS and files").font(.system(size: 12)).foregroundStyle(Glass.label2)
                Spacer()
                Button("More…") { showingMore = true }.buttonStyle(.pill)
            }
            .padding(12)
            .groupBackground()
            .padding(.bottom, 18)
        }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder _ body: @escaping () -> Content) -> some View {
        PanelGroup(title: title, content: body)
    }
}

private struct StateButton: View {
    let state: SaveState
    let look: ConsoleLook
    let disabled: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                ZStack {
                    Rectangle().fill(Color.black)
                    if let picture = state.picture, let image = NSImage(contentsOf: picture) {
                        Image(nsImage: image).resizable().interpolation(.none).aspectRatio(contentMode: .fit)
                    }
                    LookOverlay(look: look)
                }
                .frame(width: 104, height: 78)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay { CoverEdge(radius: 9) }
                .shadow(color: .black.opacity(0.3), radius: 5, y: 4)
                .offset(y: hovering ? -2 : 0)
                .padding(.bottom, 3)
                Text(state.title).font(.system(size: 12, weight: .semibold))
                Text(ConsolePanelContent.when(state)).font(.system(size: 11)).foregroundStyle(Glass.label2)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.spring(duration: 0.2, bounce: 0), value: hovering)
        .disabled(disabled)
        .accessibilityLabel(Text("Continue from \(state.title)"))
    }
}

private struct ConsoleSetupRows: View {
    let game: ConsoleGame
    let content: ConsolePanelContent
    let center: ConsoleCenter

    var body: some View {
        PanelRow(title: Text("Core")) {
            SetupChoiceMenu(title: content.cores.first(where: { $0.id == content.core })?.name ?? content.core,
                            accessibilityTitle: "Core") {
                ForEach(content.cores, id: \.id) { core in
                    Toggle(isOn: Binding(get: { content.core == core.id }, set: { selected in
                        if selected { Task { await center.setSetup(game.id) { $0.core = core.id } } }
                    })) { Text(verbatim: core.name) }
                }
            }
        }
        PanelRow(title: Text("Look")) {
            SetupChoiceMenu(title: game.setup.look.title, accessibilityTitle: "Look") {
                ForEach(ConsoleLook.allCases) { look in
                    Toggle(isOn: Binding(get: { game.setup.look == look }, set: { selected in
                        if selected { Task { await center.setSetup(game.id) { $0.look = look } } }
                    })) { Text(look.title) }
                }
            }
        }
        if game.isMultiDisc {
            PanelRow(title: Text("Disc")) {
                Picker("Disc", selection: Binding(
                    get: { min(game.setup.disc, game.discs.count - 1) },
                    set: { disc in Task { await center.setSetup(game.id) { $0.disc = disc } } }
                )) {
                    ForEach(game.discs.indices, id: \.self) { Text(verbatim: "\($0 + 1)").tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
        PanelSwitchRow(title: Text("Lower input lag"), isOn: Binding(
            get: { game.setup.lowerInputLag },
            set: { on in Task { await center.setSetup(game.id) { $0.lowerInputLag = on } } }))
        PanelSwitchRow(title: Text("Hardcore achievements"), isOn: Binding(
            get: { game.setup.hardcore },
            set: { on in Task { await center.setSetup(game.id) { $0.hardcore = on } } }))
        if game.setup.hardcore {
            Text("Hardcore turns off Continue From while you play.").font(.system(size: 11)).foregroundStyle(Glass.label2)
        }
    }
}

private struct ControllerRow: View {
    @State private var name: String?

    var body: some View {
        LabeledContent("Controller") {
            Text(name ?? String(localized: "Keyboard")).foregroundStyle(.secondary)
        }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidConnect)) { _ in read() }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidDisconnect)) { _ in read() }
        .onAppear(perform: read)
    }

    private func read() {
        name = GCController.controllers().first?.vendorName
    }
}

struct LookOverlay: View {
    let look: ConsoleLook

    var body: some View {
        switch look {
        case .original:
            EmptyView()
        case .crt:
            Canvas { context, size in
                var y: CGFloat = 0
                while y < size.height {
                    context.fill(Path(CGRect(x: 0, y: y + 2, width: size.width, height: 1)), with: .color(.black.opacity(0.32)))
                    y += 3
                }
            }
            .overlay(RadialGradient(colors: [.clear, .black.opacity(0.45)], center: .center, startRadius: 40, endRadius: 260))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        case .lcd:
            Canvas { context, size in
                var x: CGFloat = 0
                while x < size.width {
                    context.fill(Path(CGRect(x: x, y: 0, width: 0.6, height: size.height)), with: .color(.black.opacity(0.22)))
                    x += 3
                }
                var y: CGFloat = 0
                while y < size.height {
                    context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 0.6)), with: .color(.black.opacity(0.22)))
                    y += 3
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

struct ConsoleMoreSheet: View {
    let game: ConsoleGame
    let content: ConsolePanelContent
    let center: ConsoleCenter
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SheetHeader(title: Text(verbatim: game.name))
            Form {
                Section("Achievements") {
                    LabeledContent {
                        Text(content.achievements)
                    } label: {
                        Text(verbatim: "RetroAchievements")
                        if let user = center.extras.username { Text(verbatim: user).foregroundStyle(.secondary) }
                    }
                }
                if let bios = content.bios, bios.summary != .notNeeded {
                    Section {
                        ForEach(bios.files.filter(\.needed)) { file in
                            LabeledContent(file.name) {
                                Text(file.state == .found ? String(localized: "Found")
                                     : file.state == .wrongFile ? String(localized: "Not the expected file")
                                     : String(localized: "Missing"))
                                    .foregroundStyle(file.state == .found ? Color.secondary : Color.orange)
                            }
                        }
                    } header: {
                        Text(verbatim: "BIOS")
                    } footer: {
                        Text("BIOS files come from your own console. Put them in Cartouche's BIOS folder.")
                    }
                }
                Section("Files") {
                    LabeledContent {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([game.fileURL]) }
                            .disabled(!game.exists)
                    } label: {
                        Text(verbatim: game.fileURL.lastPathComponent)
                        Text(identified).foregroundStyle(.secondary)
                    }
                }
                ConsoleOptionsSections(game: game, center: center)
            }
            .formStyle(.grouped)
            Text("Covers from libretro-thumbnails. Achievements from RetroAchievements.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(.sheetProminent)
            }
        }
        .padding(22)
        .frame(width: 480, height: 460)
    }

    private var identified: String {
        switch game.identifiedBy {
        case .checksum: String(localized: "Identified by checksum")
        case .discID: String(localized: "Identified by disc ID")
        case .fileName: String(localized: "Identified by file name")
        case .chosen: String(localized: "Console chosen by you")
        }
    }
}
