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
    @Environment(StoreCenter.self) private var stores: StoreCenter?
    @Environment(ContributionsModel.self) private var contributions: ContributionsModel?

    private var content: GamePanelContent {
        GamePanelContent(game: game, compat: compat.panel(appID: game.steamAppID ?? game.compatAppID ?? -1, method: .wine),
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
                if let appID = game.steamAppID ?? game.compatAppID {
                    GameMediaCarousel(game: game, appID: appID, online: !model.isOffline)
                } else {
                    PanelHero(game: game)
                }
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(game.name)
                            .font(.system(size: 22, weight: .bold))
                            .tracking(-0.44)
                            .textSelection(.enabled)
                        Text(content.subtitle())
                            .font(.system(size: 12))
                            .foregroundStyle(Glass.label2)
                        if let notice = content.compat.ageNotice {
                            Text(notice)
                                .font(.system(size: 11))
                                .foregroundStyle(Color.orange)
                                .padding(.top, 4)
                        }
                    }
                    .padding(.top, 4)
                    .padding(.bottom, 14)
                    if game.source == .installer && game.installed {
                        GameVerificationRow(game: game)
                        // A cleaned-up name no match could vouch for: offered, never taken.
                        if let suggested = model.nameSuggestions[game.id] {
                            HStack {
                                Text(String(localized: "Identified as \(suggested)?"))
                                    .font(.system(size: 12))
                                    .foregroundStyle(Glass.label2)
                                Spacer()
                                Button(String(localized: "Rename")) { model.rename(game, to: suggested) }
                                    .buttonStyle(.pill)
                                    .controlSize(.small)
                            }
                            .padding(.bottom, 14)
                        }
                    }
                    ForEach(content.sections, id: \.self) { section in
                        block(section, content)
                    }
                    if let contributions, contributions.isAvailable {
                        CommunityBlock(game: game, model: model, compat: compat, contributions: contributions)
                    }
                    AdvancedGameRows(game: game, model: model)
                    if let controls {
                        group(String(localized: "Controls")) { ControlsRow(game: game, center: controls) }
                    }
                }
                .padding(EdgeInsets(top: 6, leading: 16, bottom: 20, trailing: 16))
            }
        }
        .scrollIndicators(.never)
        .softScrollEdges(top: 24, bottom: 32)
        .id(game.id)
        .transition(.opacity)
        .task(id: game.id) {
            InstallCenter.shared.refreshBusy(for: [game], in: model.installsFolder)
            if let appID = game.steamAppID ?? game.compatAppID { await compat.openGame(appID: appID) }
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
            if let download = activity.download(for: game) {
                DownloadBlock(download: download, center: activity)
            } else if let stores, let boot = stores.boots[game.id] {
                BootBlock(game: game, boot: boot, stores: stores)
            } else {
                HStack(spacing: 8) {
                    Button {
                        actions.perform(game.installed ? .play : .install, on: game)
                    } label: {
                        Label(content.playLabel, systemImage: game.installed ? "play.fill" : "arrow.down")
                    }
                    .buttonStyle(PlayCapsuleStyle())
                    .couchRing(controls?.couch.ringsPlay == true, radius: 19)
                    .disabled(!game.installed && model.isOffline)
                    .help(!game.installed && model.isOffline ? Text("Connect to the internet to download") : Text(verbatim: ""))
                    Menu {
                        GameMenuContent(items: GameMenu.items(for: game, in: model, stores: stores, consoles: consoles)) { actions.perform($0, on: game) }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuStyle(.button)
                    .menuIndicator(.hidden)
                    .buttonStyle(RoundFillStyle())
                    .fixedSize()
                    .accessibilityLabel(Text("More"))
                }
                .padding(.bottom, 22)
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
                    Text(estimate?.note ?? line ?? "").font(.system(size: 12)).foregroundStyle(Glass.label2)
                    Spacer()
                    Button("Details") { showingDetails = true }.buttonStyle(.pill)
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

    private func group<Content: View>(_ title: String, @ViewBuilder _ body: @escaping () -> Content) -> some View {
        PanelGroup(title: title, content: body)
    }
}

// The panel's hero: the art inset by 8, its radius concentric with the panel's
struct PanelHero<Overlay: View>: View {
    let game: Game
    var overlay: Overlay

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Glass.panelRadius - Glass.inset, style: .continuous)
        // Steam's hero art is about 3:1; at 172 pt the panel's widths keep it near 2:1, centered on the subject
        Color.clear
            .frame(height: 172)
            .overlay { CoverView(game: game, kind: .hero) }
            .overlay { overlay }
            .clipShape(shape)
            .overlay { shape.strokeBorder(Glass.edge, lineWidth: 0.5) }
            .padding(Glass.inset)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("\(game.name) artwork"))
    }
}

extension PanelHero where Overlay == EmptyView {
    init(game: Game) {
        self.init(game: game, overlay: EmptyView())
    }
}

// A titled card in the panel: the mockup's .group-h over a .form
struct PanelGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: title).groupHeader()
            VStack(alignment: .leading, spacing: 8, content: content)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .groupBackground()
        }
        .padding(.bottom, 18)
    }
}

struct EstimateRow: View {
    let estimate: GamePanelContent.Estimate

    var body: some View {
        WeightedHStack(weights: [1.3, 1, 1]) {
            StatCell(title: Text("Rating"), value: estimate.rating)
            StatCell(title: Text("Average"), value: estimate.fps)
            StatCell(title: Text("Settings"), value: estimate.settings)
        }
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
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(Glass.label3)
                .frame(width: 70, alignment: .trailing)
        }
        .opacity(layer.count < 5 ? 0.6 : 1)
    }
}

struct SetupRows: View {
    let game: Game
    @Bindable var model: LibraryModel
    let suggestion: GraphicsBackend?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let setup = model.setup(for: game.id)
        let resolved = model.resolution(for: game).setup
        let runners = game.source == .installer ? model.installRunners : model.runners.filter(\.isOffered)
        VStack(alignment: .leading, spacing: 8) {
            if model.hasMacBuild(game) {
                PanelRow(title: Text("Run")) {
                    Picker("Run", selection: Binding(
                        get: { resolved.version },
                        set: { var s = setup; s.version = $0; model.setSetup(s, for: game.id) }
                    )) {
                        ForEach(GameVersion.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                Text(resolved.version == .windows
                     ? "Steam downloads the Windows version and runs it with Steam Play. Useful when the Mac port lags behind."
                     : "The Mac build, with no translation. Usually the fastest.")
                    .font(.system(size: 12)).foregroundStyle(Glass.label2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if resolved.version == .windows {
                VStack(alignment: .leading, spacing: 8) {
                    windowsRows(setup, resolved, runners)
                }
                .transition(.opacity)
            }
        }
        .transaction(value: resolved.version) { $0.animation = nil }
    }

    // Only pairs this Mac can run are offered: no D3DMetal without a copy of it, no FEX before macOS 26
    @ViewBuilder
    private func windowsRows(_ setup: GameSetupChoice, _ resolved: GameSetup, _ runners: [Runner]) -> some View {
        let backends = model.graphicsChoices(for: game)
        let translations = model.translationChoices(for: game)
        PanelRow(title: Text("Runner")) {
            if runners.isEmpty {
                Button("Set Up a Runner…") {
                    SettingsRoute.shared.tab = .compatibility
                    openSettings()
                }
                .buttonStyle(.pill)
            } else {
                Picker("Runner", selection: Binding(
                    get: { resolved.runner?.id ?? "" },
                    set: { var s = setup; s.runnerID = $0; model.setSetup(s, for: game.id) }
                )) {
                    ForEach(runners) { runner in
                        Text(verbatim: "\(runner.kind.name) \(runner.displayVersion)").tag(runner.id)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
        }
        PanelRow(title: Text("Graphics")) {
            GraphicsMenu(selected: resolved.backend ?? backends.first ?? .d3dmetal,
                         offered: backends) { backend in
                var s = setup; s.graphics = backend; model.setSetup(s, for: game.id)
            }
            .accessibilityLabel(Text("Graphics"))
        }
        // An older Wine than the one that last ran the prefix: noted, still allowed
        if let notice = model.setupNotices[game.id] {
            Label(notice, systemImage: "exclamationmark.triangle")
                .font(.system(size: 12)).foregroundStyle(Glass.label2)
        }
        if translations.count > 1 {
            PanelRow(title: Text("Translation")) {
                Picker("Translation", selection: Binding(
                    get: { resolved.translation },
                    set: { var s = setup; s.translation = $0; model.setSetup(s, for: game.id) }
                )) {
                    ForEach(translations, id: \.self) { Text(verbatim: $0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
        if let suggestion, suggestion != resolved.backend, backends.contains(suggestion), resolved.runner != nil {
            HStack {
                Text("Most players use \(suggestion.label)").font(.system(size: 12)).foregroundStyle(Glass.label2)
                Spacer()
                Button("Use") { var s = setup; s.graphics = suggestion; model.setSetup(s, for: game.id) }
                    .buttonStyle(.pill)
                    .controlSize(.small)
            }
        }
    }
}

// The "Preparing Windows environment" phase of a store game's first launch, or its failure.
private struct BootBlock: View {
    let game: Game
    let boot: StoreBoot
    let stores: StoreCenter

    var body: some View {
        HStack(spacing: 10) {
            if boot.problem == nil {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Preparing Windows environment").font(.callout.weight(.medium))
                if let problem = boot.problem {
                    Text(problem).font(.caption).foregroundStyle(.secondary)
                } else {
                    TimelineView(.periodic(from: boot.boot.started, by: 1)) { context in
                        Text(InstallElapsed.format(from: boot.boot.started, to: context.date))
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            if boot.problem != nil {
                Button("Try Again") { stores.retryBoot(game) }
                Button("Recreate Prefix") { stores.recreateBoot(game) }
            } else {
                if let log = boot.boot.log,
                   FileManager.default.fileExists(atPath: log.path(percentEncoded: false)) {
                    Button("Show Log") { NSWorkspace.shared.open(log) }
                }
                Button("Stop") { stores.stopPlaying(game) }
            }
        }
        .controlSize(.small)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .groupBackground()
    }
}
