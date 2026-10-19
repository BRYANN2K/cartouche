import SwiftUI

struct GamePanel: View {
    let game: Game
    @Bindable var model: LibraryModel
    let compat: CompatibilityModel
    let actions: GameActionRunner

    @State private var showingDetails = false
    @State private var showingCompare = false
    @Environment(PerformanceModel.self) private var performance: PerformanceModel?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.activity) private var activity
    @Environment(ConsoleCenter.self) private var consoles: ConsoleCenter?
    @Environment(ControlsCenter.self) private var controls: ControlsCenter?

    private var content: GamePanelContent {
        GamePanelContent(game: game, compat: compat.panel(appID: game.steamAppID ?? -1, method: .wine),
                         setup: model.setup(for: game.id), play: performance?.play(appID: game.steamAppID))
    }

    var body: some View {
        if let console = game.console, let consoles {
            ConsolePanel(game: game, console: console, center: consoles, model: model, actions: actions)
        } else {
            pcBody
        }
    }

    private var pcBody: some View {
        let content = content
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                CoverView(game: game, kind: .hero)
                    .frame(height: 150)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    .accessibilityLabel(Text("\(game.name) artwork"))
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(game.name).font(.title2.weight(.bold)).textSelection(.enabled)
                        Text(content.subtitle()).foregroundStyle(.secondary)
                        if let notice = content.compat.ageNotice {
                            Text(notice).font(.callout).foregroundStyle(.orange)
                        }
                    }
                    ForEach(content.sections, id: \.self) { section in
                        block(section, content)
                    }
                    if let controls {
                        group(String(localized: "Controls")) { ControlsRow(game: game, center: controls) }
                    }
                }
                .padding(16)
            }
        }
        .id(game.id)
        .transition(Motion(reduceMotion: reduceMotion).entrance)
        .task(id: game.id) {
            // Asks MacGamingDB for this game only, when its panel opens
            if let appID = game.steamAppID { await compat.openGame(appID: appID) }
            await performance?.refresh()
        }
        .sheet(isPresented: $showingDetails) {
            GameDetailsSheet(content: content, compat: compat, model: model)
        }
        .sheet(isPresented: $showingCompare) {
            if let play = content.play { CompareSetupsSheet(game: game, play: play, model: model) }
        }
    }

    @ViewBuilder
    private func block(_ section: GamePanelContent.Section, _ content: GamePanelContent) -> some View {
        switch section {
        case .play:
            // While Steam downloads the game, its progress and controls take Play's place (P7)
            if let download = activity.download(for: game) {
                DownloadBlock(download: download, center: activity)
            } else {
                HStack(spacing: 8) {
                    Button {
                        actions.perform(game.installed ? .play : .install, on: game)
                    } label: {
                        Label(content.playLabel, systemImage: game.installed ? "play.fill" : "arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .prominentButton()
                    .couchRing(controls?.couch.ringsPlay == true)
                    .disabled(!game.installed && model.isOffline)
                    .help(!game.installed && model.isOffline ? Text("Connect to the internet to download") : Text(verbatim: ""))
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
            }
        case .yourPlay:
            if let play = content.play {
                group(section.title) {
                    YourPlayRows(play: play) { showingCompare = true }
                }
            }
        case .expected:
            group(section.title) {
                let (estimate, line) = GamePanelContent.estimate(content.compat.estimate, macReportsOn: content.compat.macReportsOn)
                if let estimate {
                    EstimateRow(estimate: estimate)
                    Divider()
                }
                HStack {
                    Text(estimate?.note ?? line ?? "").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Details") { showingDetails = true }.controlSize(.small)
                }
            }
        case .antiCheat:
            if let summary = content.compat.antiCheat {
                group(section.title) {
                    Label {
                        Text(summary.title)
                    } icon: {
                        Image(systemName: summary.level == .blocked ? "xmark.shield" : summary.level == .onlineWorks ? "checkmark.shield" : "shield")
                            .foregroundStyle(summary.level == .blocked ? Color.red : summary.level == .onlineWorks ? Color.green : Color.secondary)
                    }
                }
            }
        case .graphics:
            group(section.title) {
                ForEach(content.layers) { layer in
                    LayerRow(layer: layer, isBest: layer.layer == content.bestLayer)
                }
            }
        case .setup:
            group(section.title) {
                SetupRows(game: game, model: model, suggestion: content.suggestedBackend)
            }
        }
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

struct EstimateRow: View {
    let estimate: GamePanelContent.Estimate

    var body: some View {
        HStack(alignment: .top) {
            cell(Text("Rating"), estimate.rating)
            cell(Text("Average"), estimate.fps)
            cell(Text("Settings"), estimate.settings)
        }
    }

    private func cell(_ title: Text, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            title.font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct LayerRow: View {
    let layer: LayerReport
    let isBest: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text(layer.layer.label)
                .fontWeight(isBest ? .semibold : .regular)
                .frame(width: 80, alignment: .leading)
            ProgressView(value: layer.average, total: 5)
                .tint(isBest ? .green : .secondary)
                .accessibilityLabel(Text("\(layer.layer.label) average"))
            Text(GamePanelContent.reportCount(layer.count))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .trailing)
        }
        // Fewer than 5 reports say little, so they are dimmed
        .opacity(layer.count < 5 ? 0.6 : 1)
    }
}

struct SetupRows: View {
    let game: Game
    @Bindable var model: LibraryModel
    let suggestion: GraphicsBackend?

    var body: some View {
        let setup = model.setup(for: game.id)
        let resolved = model.resolution(for: game).setup
        let runners = model.runners.filter(\.isOffered)
        // A game with a Mac build runs it unless the Windows version is picked (P3)
        if model.hasMacBuild(game) {
            Picker("Run", selection: Binding(
                get: { resolved.version },
                set: { var s = setup; s.version = $0; model.setSetup(s, for: game.id) }
            )) {
                ForEach(GameVersion.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            Text(resolved.version == .windows
                 ? "Steam downloads the Windows version and runs it with Steam Play. Useful when the Mac port lags behind."
                 : "The Mac build, with no translation. Usually the fastest.")
                .font(.callout).foregroundStyle(.secondary)
        }
        if resolved.version == .windows {
            windowsRows(setup, resolved, runners)
        }
    }

    // Only pairs this Mac can run are offered: no D3DMetal without a copy of it, no FEX before macOS 26
    @ViewBuilder
    private func windowsRows(_ setup: GameSetupChoice, _ resolved: GameSetup, _ runners: [Runner]) -> some View {
        let backends = resolved.runner == nil ? GraphicsBackend.allCases : model.graphicsChoices(for: game)
        let translations = model.translationChoices(for: game)
        Picker("Runner", selection: Binding(
            get: { resolved.runner?.id ?? "" },
            set: { var s = setup; s.runnerID = $0; model.setSetup(s, for: game.id) }
        )) {
            if runners.isEmpty { Text("No runner set up").tag("") }
            ForEach(runners) { runner in
                Text(verbatim: "\(runner.kind.name) \(runner.displayVersion)").tag(runner.id)
            }
        }
        .disabled(runners.isEmpty)
        Picker("Graphics", selection: Binding(
            get: { resolved.backend ?? backends.first ?? .d3dmetal },
            set: { var s = setup; s.graphics = $0; model.setSetup(s, for: game.id) }
        )) {
            ForEach(backends) { Text(verbatim: $0.label).tag($0) }
        }
        .disabled(resolved.runner == nil)
        if translations.count > 1 {
            Picker("Translation", selection: Binding(
                get: { resolved.translation },
                set: { var s = setup; s.translation = $0; model.setSetup(s, for: game.id) }
            )) {
                ForEach(translations, id: \.self) { Text(verbatim: $0.label).tag($0) }
            }
            .pickerStyle(.segmented)
        }
        if let suggestion, suggestion != resolved.backend, backends.contains(suggestion), resolved.runner != nil {
            HStack {
                Text("Most players use \(suggestion.label)").foregroundStyle(.secondary)
                Spacer()
                Button("Use") { var s = setup; s.graphics = suggestion; model.setSetup(s, for: game.id) }
                    .controlSize(.small)
            }
        }
    }
}
