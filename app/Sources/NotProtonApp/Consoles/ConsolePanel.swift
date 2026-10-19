import AppKit
import GameController
import RetroArchKit
import SwiftUI

// The panel of a console game, as launcher.html's renderRetroInspector
struct ConsolePanel: View {
    let game: Game
    let console: ConsoleGame
    let center: ConsoleCenter
    @Bindable var model: LibraryModel
    let actions: GameActionRunner

    @State private var showingMore = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var content: ConsolePanelContent? {
        guard let system = center.console(of: console) else { return nil }
        return ConsolePanelContent(game: console, console: system, states: center.states(for: console),
                                   bios: center.bios(for: console),
                                   playing: center.isPlaying(console.id) ? center.playing : nil,
                                   route: center.route(for: system))
    }

    var body: some View {
        if let content {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    CoverView(game: game, kind: .hero)
                        .frame(height: 170)
                        .frame(maxWidth: .infinity)
                        .overlay { LookOverlay(look: console.setup.look) }
                        .clipped()
                        .accessibilityLabel(Text("\(game.name) screenshot"))
                    VStack(alignment: .leading, spacing: 14) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(game.name).font(.title2.weight(.bold)).textSelection(.enabled)
                            Text(content.subtitle()).foregroundStyle(.secondary)
                        }
                        ForEach(content.sections, id: \.self) { section in
                            block(section, content)
                        }
                    }
                    .padding(16)
                }
            }
            .id(game.id)
            .task(id: game.id) { if let system = center.console(of: console) { await center.refreshEmulators(for: system) } }
            .transition(Motion(reduceMotion: reduceMotion).entrance)
            .sheet(isPresented: $showingMore) {
                ConsoleMoreSheet(game: console, content: content, center: center)
            }
        }
    }

    @ViewBuilder
    private func block(_ section: ConsolePanelContent.Section, _ content: ConsolePanelContent) -> some View {
        switch section {
        case .play:
            HStack(spacing: 8) {
                Button {
                    Task { await center.play(console.id, resume: content.hasAutoState, reduceMotion: reduceMotion) }
                } label: {
                    Label(content.playLabel, systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .prominentButton()
                .disabled(!content.canPlay)
                Menu {
                    GameMenuContent(items: GameMenu.items(for: game, in: model)) { actions.perform($0, on: game) }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .controlSize(.large)
                .accessibilityLabel(Text("More"))
            }
            if let note = content.playNote {
                Text(note).font(.callout).foregroundStyle(content.route.missingText == nil ? Color.secondary : Color.orange)
            }
        case .bios:
            if let warning = content.biosWarning {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(warning.title).fontWeight(.semibold)
                        Text(warning.detail).font(.callout).foregroundStyle(.secondary)
                        Button("Show BIOS Folder") {
                            try? FileManager.default.createDirectory(at: center.paths.bios, withIntermediateDirectories: true)
                            NSWorkspace.shared.open(center.paths.bios)
                        }
                        .controlSize(.small)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityElement(children: .combine)
            }
        case .continueFrom:
            group(section.title) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(content.states) { state in
                            StateButton(state: state, look: console.setup.look, disabled: !content.canPlay) {
                                Task {
                                    await center.play(console.id, slot: state.slot, resume: state.isAuto, reduceMotion: reduceMotion)
                                }
                            }
                        }
                    }
                }
            }
        case .stats:
            HStack(alignment: .top) {
                stat(Text("Played"), content.played)
                stat(Text("Achievements"), content.achievements)
            }
            .padding(12)
            .groupBackground()
        case .setup:
            group(section.title) {
                EmulatorRows(console: content.console, route: content.route, center: center)
                if content.route == .retroArch { ConsoleSetupRows(game: console, content: content, center: center) }
            }
        case .controls:
            group(section.title) {
                ControllerRow()
            }
        case .more:
            HStack {
                Text("Achievements, BIOS and files").foregroundStyle(.secondary)
                Spacer()
                Button("More…") { showingMore = true }.controlSize(.small)
            }
            .padding(12)
            .groupBackground()
        }
    }

    private func stat(_ title: Text, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            title.font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func group<Content: View>(_ title: String, @ViewBuilder _ body: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 8, content: body)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .groupBackground()
        }
    }
}

// One state under Continue From: the picture RetroArch saved with it
private struct StateButton: View {
    let state: SaveState
    let look: ConsoleLook
    let disabled: Bool
    let action: () -> Void

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
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                Text(state.title).font(.caption.weight(.semibold))
                Text(ConsolePanelContent.when(state)).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel(Text("Continue from \(state.title)"))
    }
}

private struct ConsoleSetupRows: View {
    let game: ConsoleGame
    let content: ConsolePanelContent
    let center: ConsoleCenter

    var body: some View {
        Picker("Core", selection: Binding(
            get: { content.core },
            set: { core in Task { await center.setSetup(game.id) { $0.core = core } } }
        )) {
            ForEach(content.cores, id: \.id) { Text(verbatim: $0.name).tag($0.id) }
        }
        Picker("Look", selection: Binding(
            get: { game.setup.look },
            set: { look in Task { await center.setSetup(game.id) { $0.look = look } } }
        )) {
            ForEach(ConsoleLook.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        if game.isMultiDisc {
            Picker("Disc", selection: Binding(
                get: { min(game.setup.disc, game.discs.count - 1) },
                set: { disc in Task { await center.setSetup(game.id) { $0.disc = disc } } }
            )) {
                ForEach(game.discs.indices, id: \.self) { Text(verbatim: "\($0 + 1)").tag($0) }
            }
            .pickerStyle(.segmented)
        }
        Toggle("Lower input lag", isOn: Binding(
            get: { game.setup.lowerInputLag },
            set: { on in Task { await center.setSetup(game.id) { $0.lowerInputLag = on } } }))
        Toggle("Hardcore achievements", isOn: Binding(
            get: { game.setup.hardcore },
            set: { on in Task { await center.setSetup(game.id) { $0.hardcore = on } } }))
        if game.setup.hardcore {
            Text("Hardcore turns off Continue From while you play.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

// The controller RetroArch reads, as macOS sees it
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

// The panel's picture in the look RetroArch applies: scanlines and a vignette
// for CRT, the pixel grid for LCD
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

// More…: what the panel leaves out
struct ConsoleMoreSheet: View {
    let game: ConsoleGame
    let content: ConsolePanelContent
    let center: ConsoleCenter
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(verbatim: game.name).font(.title2.weight(.bold))
            Form {
                Section("Achievements") {
                    LabeledContent {
                        Text(content.achievements)
                    } label: {
                        Text(verbatim: "RetroAchievements")
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
            }
            .formStyle(.grouped)
            Text("Covers from libretro-thumbnails.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
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
