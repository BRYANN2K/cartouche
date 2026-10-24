import RetroArchKit
import SwiftUI

struct GamePanel: View {
    let game: Game
    @Bindable var model: LibraryModel
    let compat: CompatibilityModel
    let actions: GameActionRunner

    @State private var showingDetails = false
    @State private var showingCompare = false
    @State private var showingMore = false
    @State private var showingJoin = false
    @State private var consoleDetails: (id: String, states: [SaveState], bios: BIOSStatus?)?
    @Environment(PerformanceModel.self) private var performance: PerformanceModel?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.activity) private var activity
    @Environment(ConsoleCenter.self) private var consoles: ConsoleCenter?
    @Environment(ControlsCenter.self) private var controls: ControlsCenter?
    @Environment(StoreCenter.self) private var stores: StoreCenter?
    @Environment(ContributionsModel.self) private var contributions: ContributionsModel?
    @Environment(\.gameVerification) private var verification

    private var content: GamePanelContent {
        GamePanelContent(game: game, compat: compat.panel(appID: game.steamAppID ?? game.compatAppID ?? -1, method: game.version == .mac ? .native : .wine),
                         setup: model.setup(for: game.id), play: performance?.play(appID: game.steamAppID ?? game.compatAppID))
    }

    private var launching: Bool { GameMenu.steamLaunching(game, activity: activity) }

    private var running: Bool {
        GamePanelContent.isRunning(game, store: stores?.playing.contains(game.id) == true,
                                   local: actions.installs.isPlaying(game),
                                   steam: GameMenu.steamRunning(game, in: model, activity: activity))
    }

    private var consoleContent: ConsolePanelContent? {
        guard let console = game.console, let consoles, let consoleDetails, consoleDetails.id == console.id,
              let system = consoles.console(of: console) else { return nil }
        var content = ConsolePanelContent(game: console, console: system, states: consoleDetails.states,
                                          bios: consoleDetails.bios,
                                          playing: consoles.isPlaying(console.id) ? consoles.playing : nil,
                                          route: consoles.route(for: system))
        content.signedIn = consoles.extras.username != nil
        content.progress = consoles.extras.progress(for: console)
        return content
    }

    private var showsAdvanced: Bool {
        guard game.console == nil else { return false }
        let setup = model.resolution(for: game).setup
        guard setup.version == .windows else { return false }
        return !AdvancedSupport.options(runner: setup.runner, backend: setup.backend,
                                       translation: setup.translation, availability: model.backendAvailability).isEmpty
    }

    var body: some View {
        let content = content
        ZStack(alignment: .top) {
            if game.console == nil || consoleContent != nil {
                scroll(content)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: game.id) {
            InstallCenter.shared.refreshBusy(for: [game], in: model.installsFolder)
            if game.source == .installer { model.refreshExeOptions(for: [game], force: true) }
            if let appID = game.steamAppID ?? game.compatAppID { await compat.openGame(appID: appID) }
            await performance?.refresh()
            await stores?.loadDetails(game)
            if let console = game.console, let consoles, let system = consoles.console(of: console) {
                await consoles.refreshEmulators(for: system)
            }
        }
        .task(id: game.console.map { "\($0.id)#\(consoles?.statesChanged ?? 0)" } ?? "") {
            guard let console = game.console, let consoles else { return }
            async let states = consoles.states(for: console)
            async let bios = consoles.bios(for: console)
            consoleDetails = await (console.id, states, bios)
        }
        .task(id: game.console?.id) {
            guard let console = game.console, let consoles else { return }
            await consoles.extras.refresh(console)
        }
        .sheet(isPresented: $showingDetails) {
            GameDetailsSheet(content: content, compat: compat, model: model)
        }
        .sheet(isPresented: $showingCompare) {
            if let play = content.play { CompareSetupsSheet(game: game, play: play, model: model) }
        }
        .sheet(isPresented: $showingMore) {
            if let console = game.console, let consoleContent, let consoles {
                ConsoleMoreSheet(game: console, content: consoleContent, center: consoles)
            }
        }
        .sheet(isPresented: $showingJoin) {
            if let consoles { NetplayJoinSheet(center: consoles) }
        }
        .netplayExplanations(consoles?.netplayFlow)
        .onChange(of: game.id) {
            showingMore = false
            showingJoin = false
        }
    }

    private func scroll(_ content: GamePanelContent) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                panelHero
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text(game.name)
                            .font(.system(size: 22, weight: .bold))
                            .tracking(-0.44)
                            .textSelection(.enabled)
                            if game.source == .installer && game.installed {
                                GameVerificationBadge(game: game)
                            }
                        }
                        Text(consoleContent?.subtitle() ?? content.metadataLine())
                            .font(.system(size: 12))
                            .foregroundStyle(Glass.label2)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .help(content.storageLine ?? "")
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
                        if verification?.progress(for: game.id) != nil {
                            GameVerificationRow(game: game)
                        }
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
                    if let console = game.console, let consoles, let consoleContent {
                        ConsolePanel(game: game, console: console, content: consoleContent, center: consoles,
                                     model: model, actions: actions, showingMore: $showingMore, showingJoin: $showingJoin)
                    } else if game.console == nil {
                        let modules = content.modules(showsAdvanced: showsAdvanced)
                        let communityBefore = modules.first { $0 == .advanced || $0 == .controls }
                        ForEach(modules, id: \.self) { section in
                            if section == communityBefore, let contributions, contributions.isAvailable {
                                CommunityBlock(game: game, model: model, compat: compat, contributions: contributions)
                            }
                            block(section, content)
                        }
                    }
                }
                .padding(EdgeInsets(top: 6, leading: 16, bottom: 20, trailing: 16))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
        // The page grows once saves and art arrive. Keep the title in view, including on that growth.
        .defaultScrollAnchor(.top, for: .initialOffset)
        .defaultScrollAnchor(.top, for: .sizeChanges)
        .softScrollEdges(top: 24, bottom: 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .id(game.id)
        .transition(.opacity)
    }

    @ViewBuilder
    private var panelHero: some View {
        if let console = game.console {
            PanelHero(game: game, overlay: LookOverlay(look: console.setup.look))
                .accessibilityLabel(Text("\(game.name) screenshot"))
        } else if game.source == .gog {
            GameMediaCarousel(game: game, appID: Int(game.id.split(separator: ":").last ?? "") ?? 0, online: !model.isOffline)
        } else if let appID = game.steamAppID ?? game.compatAppID {
            GameMediaCarousel(game: game, appID: appID, online: !model.isOffline)
        } else {
            PanelHero(game: game)
        }
    }

    @ViewBuilder
    private func block(_ section: PanelModule, _ content: GamePanelContent) -> some View {
        switch section {
        case .play:
            if let download = activity.download(for: game) {
                DownloadBlock(download: download, center: activity)
            } else if game.source == .steam, !game.installed,
                      let install = SteamInstallCenter.shared.status, install.game.id == game.id,
                      install.state != "cancelled" {
                SteamInstallBlock(status: install) { model.installRequest = game }
            } else if let stores, let boot = stores.boots[game.id] {
                BootBlock(game: game, boot: boot, stores: stores)
            } else {
                let running = self.running
                HStack(spacing: 8) {
                    Button {
                        actions.perform(running ? .stopGame : (game.installed ? .play : .install), on: game)
                    } label: {
                        if launching {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Launching…")
                            }
                        } else {
                            Label(content.actionLabel(running: running),
                                  systemImage: running ? "stop.fill" : (game.installed ? "play.fill" : "arrow.down"))
                        }
                    }
                    .buttonStyle(PlayCapsuleStyle(tint: running ? .red : .accentColor))
                    .couchRing(controls?.couch.ringsPlay == true, radius: 19)
                    .disabled(launching || (!game.installed && model.isOffline))
                    .help(!game.installed && model.isOffline ? Text("Connect to the internet to download") : Text(verbatim: ""))
                    Menu {
                        GameMenuContent(items: GameMenu.items(for: game, in: model, stores: stores, installs: actions.installs,
                                                              consoles: consoles, activity: activity)) { actions.perform($0, on: game) }
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
            } else if game.installed {
                group(section.title) {
                    WeightedHStack(weights: [1.3, 1, 1]) {
                        StatCell(title: Text("Average"), value: "–")
                        StatCell(title: Text("1% low"), value: "–")
                        StatCell(title: Text("Played"), value: "–")
                    }
                    Text("No sessions yet")
                        .font(.system(size: 12))
                        .foregroundStyle(Glass.label2)
                }
            }
        case .bios, .continueFrom, .playTogether, .more:
            EmptyView()
        case .advanced:
            AdvancedGameRows(game: game, model: model)
        case .controls:
            if let controls {
                group(section.title) { ControlsRow(game: game, center: controls) }
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
                SetupRows(game: game, model: model, suggestion: content.reportedBackend, actions: actions)
                    .disabled(running || launching)
                    .help(running ? Text("Stop the game to change its setup.") : Text(verbatim: ""))
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
        Color.clear
            .aspectRatio(GameMediaStore.aspect, contentMode: .fit)
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

// The game's Wine Tools as its menu lists them, one pill each
struct WineToolsRow: View {
    let items: [GameMenuItem]
    let perform: (GameAction) -> Void

    var body: some View {
        let tools = items.filter { !$0.isDivider }
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 8, alignment: .leading)],
                  alignment: .leading, spacing: 8) {
            ForEach(Array(tools.enumerated()), id: \.offset) { _, item in
                Button(item.title) { item.action.map(perform) }
                    .buttonStyle(.pill)
                    .disabled(item.disabled)
                    .opacity(item.disabled ? 0.45 : 1)
            }
        }
        if tools.contains(where: \.disabled) {
            Text("Stop the game to change its prefix.")
                .font(.system(size: 11)).foregroundStyle(Glass.label2)
        }
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
    var actions: GameActionRunner? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openSettings) private var openSettings
    @Environment(RunnersModel.self) private var runnerCatalog: RunnersModel?
    @Environment(StoreCenter.self) private var stores: StoreCenter?
    @Environment(\.activity) private var activity
    @State private var changingRunner = false

    var body: some View {
        let setup = model.setup(for: game.id)
        let resolved = model.resolution(for: game).setup
        let runners = game.source == .installer || game.source.isStore ? model.installRunners : model.steamRunners
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

    private func chooseRunner(_ id: String) {
        var choice = model.setup(for: game.id)
        choice.runnerID = id
        model.setSetup(choice, for: game.id)
    }

    private func downloadRunner(_ id: String, catalog: RunnersModel) async {
        changingRunner = true
        defer { changingRunner = false }
        await catalog.perform(.download, on: id)
        await model.reloadRunners?()
        let offered = game.source == .steam ? model.steamRunners : model.installRunners
        guard offered.contains(where: { $0.id == id }) else {
            model.problem = catalog.message ?? String(localized: "The runner could not be installed.")
            return
        }
        guard !GameMenu.isRunning(game, in: model, stores: stores, activity: activity) else { return }
        chooseRunner(id)
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
                SetupChoiceMenu(title: changingRunner ? String(localized: "Downloading…") :
                                    resolved.runner.map(RunnerChoices.label) ?? String(localized: "Choose Runner"),
                                accessibilityTitle: "Runner") {
                    ForEach(runners) { runner in
                        Toggle(isOn: Binding(get: { resolved.runner?.id == runner.id },
                                             set: { if $0 { chooseRunner(runner.id) } })) {
                            Text(verbatim: RunnerChoices.title(id: runner.id, name: runner.name, version: runner.displayVersion))
                        }
                    }
                    if let catalog = runnerCatalog {
                        let downloads = RunnerChoices.downloads(manifest: catalog.manifest, installed: model.runners, steam: false)
                        if !downloads.isEmpty {
                            Section("Download a Runner") {
                                ForEach(downloads) { build in
                                    Button {
                                        Task { await downloadRunner(build.id, catalog: catalog) }
                                    } label: {
                                        Text(verbatim: RunnerChoices.title(id: build.id, name: build.name, version: build.displayVersion))
                                    }
                                    .disabled(catalog.busy.contains(build.id) || model.isOffline)
                                }
                            }
                        }
                    }
                    Divider()
                    Button("Manage Runners…") {
                        SettingsRoute.shared.tab = .compatibility
                        openSettings()
                    }
                }
                .disabled(changingRunner)
            }
        }
        PanelRow(title: Text("Graphics")) {
            GraphicsMenu(selected: resolved.backend ?? backends.first ?? .d3dmetal,
                         offered: backends, controlWidth: SetupMenuLabel.controlWidth) { backend in
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
        if let suggestion, let runner = resolved.runner,
           let action = GamePanelContent.suggestionAction(
               suggestion, current: resolved.backend, offered: backends,
               needsToolkit: BackendSupport.needsToolkit(for: runner, translation: resolved.translation,
                                                         availability: model.backendAvailability)) {
            HStack {
                Text("Most players use \(suggestion.label)").font(.system(size: 12)).foregroundStyle(Glass.label2)
                Spacer()
                switch action {
                case .use(let backend):
                    Button("Use") { var s = setup; s.graphics = backend; model.setSetup(s, for: game.id) }
                        .buttonStyle(.pill)
                        .controlSize(.small)
                case .getD3DMetal:
                    // The Game Porting Toolkit import lives with the runners
                    Button("Get D3DMetal…") {
                        SettingsRoute.shared.tab = .compatibility
                        openSettings()
                    }
                    .buttonStyle(.pill)
                    .controlSize(.small)
                }
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

private struct SteamInstallBlock: View {
    let status: SteamInstallCenter.Status
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch status.state {
            case "license":
                Text("License agreements").font(.headline)
                ForEach(status.licenses) { license in
                    Link("Read agreement", destination: license.url)
                }
                HStack {
                    Button("Cancel", role: .cancel) { SteamInstallCenter.shared.cancel() }
                    Button("Accept and Install") { SteamInstallCenter.shared.accept() }
                        .disabled(status.licenses.isEmpty)
                }
            case "failed":
                Text(status.message ?? String(localized: "Installation failed.")).foregroundStyle(.secondary)
                Button("Try Again", action: retry)
            default:
                HStack(spacing: 8) {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(status.state == "queued" ? "Download queued" : "Preparing installation…")
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity)
                    .frame(height: 38)
                    .capsuleField()
                    Button("Cancel", systemImage: "xmark") { SteamInstallCenter.shared.cancel() }
                        .labelStyle(.iconOnly)
                        .buttonStyle(RoundFillStyle())
                        .help(Text("Cancel Installation"))
                }
            }
        }
        .padding(.bottom, 22)
    }
}
