import SwiftUI

// The mockup's floating glass sidebar: its own rows rather than a system List,
// so the selection is the mockup's quiet fill instead of the accent slab
struct LibrarySidebar: View {
    @Bindable var model: LibraryModel
    @Environment(ConsoleCenter.self) private var consoles: ConsoleCenter?

    private var items: [SidebarItem] {
        [.all, .favorites, .source(.steam), .source(.epic), .source(.gog), .source(.amazon), .source(.installer)]
            + model.consoles.map { .source(.console($0)) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header(Text("Library"))
                row(.all) { Image(systemName: "square.grid.2x2") }
                row(.favorites) { Image(systemName: "star") }
                header(Text("PC"))
                ForEach([GameSource.steam, .epic, .gog, .amazon], id: \.self) { source in
                    row(.source(source)) {
                        if let mark = PlatformMark.source(source) { PlatformMarkView(mark: mark) }
                    }
                }
                row(.source(.installer)) { Image(systemName: "shippingbox") }
                consolesHeader
                ForEach(model.consoles, id: \.self) { id in
                    ConsoleSidebarRow(id: id, model: model)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .scrollIndicators(.never)
        .softScrollEdges()
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { step(-1) }
        .onKeyPress(.downArrow) { step(1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Sidebar"))
    }

    private func step(_ by: Int) -> KeyPress.Result {
        guard let index = items.firstIndex(of: model.selection) else { return .ignored }
        let next = index + by
        guard items.indices.contains(next) else { return .handled }
        model.selection = items[next]
        return .handled
    }

    private func header(_ title: Text) -> some View {
        title
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Glass.label3)
            .padding(EdgeInsets(top: 14, leading: 10, bottom: 5, trailing: 10))
            .accessibilityAddTraits(.isHeader)
    }

    private var consolesHeader: some View {
        HStack(spacing: 6) {
            header(Text("Consoles"))
            Spacer()
            if consoles?.downloading.isEmpty == false {
                ProgressView().controlSize(.mini)
                    .help(Text("Downloading cores…"))
                    .padding(.top, 9)
            }
            Button {
                model.showAddConsoles = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 20, height: 20)
                    .contentShape(.rect)
            }
            .buttonStyle(SidebarAddButtonStyle())
            .padding(.top, 9)
            .padding(.trailing, 6)
            .help(Text("Add Consoles"))
            .accessibilityLabel(Text("Add Consoles"))
        }
    }

    private func row<Icon: View>(_ item: SidebarItem, @ViewBuilder icon: @escaping () -> Icon) -> some View {
        SidebarRow(title: LibraryModel.title(item), badge: model.badge(item), alert: model.isExpired(item),
                   selected: model.selection == item, icon: icon) {
            model.selection = item
        }
    }
}

struct SidebarRow<Icon: View>: View {
    let title: String
    let badge: String?
    var alert = false
    let selected: Bool
    @ViewBuilder let icon: () -> Icon
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                icon()
                    .font(.system(size: 14))
                    .frame(width: 16, height: 16)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                Text(verbatim: title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if let badge {
                    if alert {
                        Text(verbatim: badge)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(minWidth: 16, minHeight: 16)
                            .background(Color.red, in: .capsule)
                    } else {
                        Text(verbatim: badge)
                            .font(.system(size: 12))
                            .monospacedDigit()
                            .foregroundStyle(Glass.label3)
                    }
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: Glass.rowRadius, style: .continuous)
                        .fill(Glass.fill2)
                } else if hovering {
                    RoundedRectangle(cornerRadius: Glass.rowRadius, style: .continuous)
                        .fill(Glass.fill)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

private struct SidebarAddButtonStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(hovering ? Color.primary : Glass.label2)
            .background(hovering || configuration.isPressed ? Glass.fill2 : .clear,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .onHover { hovering = $0 }
    }
}

struct LibraryWindow: View {
    @Bindable var model: LibraryModel
    let compat: CompatibilityModel
    @Bindable var steamSetup: SteamSetup
    let actions: GameActionRunner

    @State private var searchFocused = false
    @State private var width: CGFloat = 1280
    @State private var overlayDismissedFor: String?
    @State private var dropTargeted = false
    @State private var adding = AddGamesNavigation()
    @Environment(\.dropClassifier) private var dropClassifier
    @Environment(\.gameVerification) private var verification
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.activity) private var activity
    @Environment(ConsoleCenter.self) private var consoles: ConsoleCenter?

    private var panelGame: Game? {
        guard model.showPanel, model.screen.showsPanel else { return nil }
        return model.selectedGame
    }

    // With nothing selected the window keeps the color of the first game it shows
    private var backdropGame: Game? {
        if let game = model.selectedGame { return game }
        if case .grid(let sections) = model.screen { return sections.first?.games.first }
        return nil
    }

    var body: some View {
        let motion = Motion(reduceMotion: reduceMotion)
        let layout = WindowLayout(width: width, sidebar: model.showSidebar)
        let panelGame = panelGame
        let docked = panelGame != nil && layout.docksPanel
        let floating = panelGame != nil && !layout.docksPanel && overlayDismissedFor != model.selectedGameID
        // Split in three so the type checker handles each chain on its own
        presentations(
            NavigationStack {
                chrome(columns(layout, panelGame: panelGame, docked: docked, floating: floating),
                       layout, motion: motion, floating: floating)
            }
        )
    }

    private func columns(_ layout: WindowLayout, panelGame: Game?, docked: Bool, floating: Bool) -> some View {
        HStack(spacing: 0) {
            if layout.sidebar > 0 {
                sidebar(layout)
                    .transition(reduceMotion ? .opacity : .move(edge: .leading).combined(with: .opacity))
            }
            main(layout)
                .padding(.leading, layout.sidebar > 0 ? Glass.inset : 0)
                .padding(.trailing, docked ? Glass.inset : floating ? layout.panel + Glass.inset * 2 : 0)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if docked, let game = panelGame {
                panel(game, layout)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .trailing) {
            // Too narrow for three columns and the panel: it floats over the grid until closed
            if floating, let game = panelGame {
                panel(game, layout)
                    .overlay(alignment: .topTrailing) {
                        Button {
                            overlayDismissedFor = model.selectedGameID
                        } label: {
                            Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                        }
                        .buttonStyle(RoundGlassStyle(size: 26))
                        .keyboardShortcut(.cancelAction)
                        .padding(Glass.inset * 2 + 4)
                        .help(Text("Hide Game Panel"))
                        .accessibilityLabel(Text("Hide Game Panel"))
                    }
                    .shadow(color: .black.opacity(0.3), radius: 24, x: -6)
                    .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
            }
        }
    }

    private func chrome<V: View>(_ content: V, _ layout: WindowLayout, motion: Motion, floating: Bool) -> some View {
        content
            .overlay { DropOverlay(targeted: dropTargeted) }
            .dropDestination(for: URL.self) { urls, _ in
                handleDrop(urls)
            } isTargeted: { dropTargeted = $0 }
            .background {
                CoverBackdrop(game: backdropGame,
                              override: backdropGame.flatMap { model.coverOverride(for: $0.id) })
                    .ignoresSafeArea()
            }
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
            .scrollBounceBehavior(.basedOnSize, axes: [.vertical, .horizontal])
            .animation(motion.panel, value: floating)
            .animation(motion.panel, value: layout.sidebar > 0)
            .transaction(value: model.selection) { $0.animation = nil }
            .toolbar { libraryToolbar }
            .toolbar(removing: .title)
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            .navigationTitle(model.title)
            .navigationSubtitle(model.subtitle)
            .onChange(of: model.searchFocusRequests) { searchFocused = true }
            .onChange(of: layout.docksPanel) { _, docks in
                // Going narrow keeps the grid in view; the panel comes back when a game is picked
                if !docks { overlayDismissedFor = model.selectedGameID }
            }
    }

    private func presentations<V: View>(_ content: V) -> some View {
        content
            .sheet(isPresented: $model.showConsoleImport, onDismiss: {
                if adding.flowDismissed() { model.showAddGames = true }
            }) {
                ConsoleImportSheet(back: consoleBack)
            }
            .sheet(isPresented: $model.showAddGames, onDismiss: { adding.sheetDismissed() }) {
                if let drop = adding.drop {
                    DropSheet(model: drop, actions: dropActions)
                        .onChange(of: drop.isPresented) { _, presented in
                            if !presented { model.showAddGames = false }
                        }
                } else {
                    AddGamesDropSheet(add: { _ = handleDrop($0) })
                }
            }
            .sheet(isPresented: $model.showAddConsoles) {
                if let consoles { AddConsolesSheet(center: consoles) }
            }
            .sheet(item: $model.installRequest) { game in
                StoreInstallSheet(game: game, model: model, stores: actions.stores)
            }
            .sheet(item: $model.coverSearch) { game in
                CoverSearchSheet(game: game, model: model, choices: compat.choices)
            }
            .overlay {
                if let consoles, let powerOn = consoles.powerOn, !reduceMotion {
                    CRTPowerOn(powerOn: powerOn) { consoles.powerOn = nil }
                }
            }
            .onChange(of: model.verificationRequest) { _, game in
                guard let game else { return }
                model.verificationRequest = nil
                if let verification {
                    verification.verify(game)
                } else {
                    model.problem = String(localized: "File verification is unavailable in this build.")
                }
            }
            .sheet(item: Binding(get: { verification?.mismatch }, set: { value in
                if value == nil, let mismatch = verification?.mismatch {
                    verification?.cancelMismatch(gameID: mismatch.gameID)
                }
            })) { mismatch in
                if let verification { GameVerificationMismatchSheet(mismatch: mismatch, verification: verification) }
            }
            .installSheet(library: model, compat: compat)
    }

    private var consoleBack: (@MainActor () -> Void)? {
        guard adding.canReturn else { return nil }
        return { adding.returnOnDismiss() }
    }

    private func handleDrop(_ urls: [URL]) -> Bool {
        guard !urls.isEmpty else { return false }
        // A checksum list dropped on a selected installed game verifies it (ADR 0026).
        if urls.count == 1, urls[0].pathExtension.lowercased() == "md5",
           let game = model.selectedGame, game.source == .installer, game.installed,
           let verification {
            verification.verify(game, checksums: urls[0])
            return true
        }
        if let dropClassifier {
            let next = DropModel(classifier: dropClassifier)
            adding.drop = next
            next.start(urls)
        } else {
            let next = DropModel()
            next.show(.failed(.detectionUnavailable))
            adding.drop = next
        }
        model.showAddGames = true
        return true
    }

    private var dropActions: DropActions {
        var actions = DropActions()
        // Back from the flow's first step brings this sheet back as it was left
        let back: @MainActor () -> Void = {
            if adding.restore() { model.showAddGames = true }
        }
        actions.install = { installer in
            adding.handOff { InstallCenter.shared.open([installer.setup], back: back) }
            model.showAddGames = false
        }
        actions.importGame = { game, exe, storage in
            let decided = exe.map { InstallSheetModel.Decided(exe: $0, storage: storage == .copy ? .copy : .inPlace) }
            adding.handOff { InstallCenter.shared.open([game.folder], decided: decided, back: back) }
            model.showAddGames = false
        }
        actions.addROMs = { roms in
            guard let consoles else { return }
            adding.handOff {
                consoles.importFlow.start(roms.groups.flatMap(\.files))
                model.showConsoleImport = true
            }
            model.showAddGames = false
        }
        actions.addConsole = { id in
            guard let consoles else { return }
            Task { await consoles.add([id]) }
        }
        actions.chooseAnother = {
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = true
            if panel.runModal() == .OK { _ = handleDrop(panel.urls) }
        }
        return actions
    }

    private func sidebar(_ layout: WindowLayout) -> some View {
        LibrarySidebar(model: model)
            .activitySlot(activity, library: model)
            .frame(width: layout.sidebar)
            .frame(maxHeight: .infinity)
            .floatingPanel()
            .padding([.top, .bottom, .leading], Glass.inset)
    }

    private func panel(_ game: Game, _ layout: WindowLayout) -> some View {
        GamePanel(game: game, model: model, compat: compat, actions: actions)
            .frame(width: layout.panel)
            .frame(maxHeight: .infinity)
            .floatingPanel(liquid: false)
            .padding([.top, .bottom, .trailing], Glass.inset)
    }

    @ViewBuilder
    private func main(_ layout: WindowLayout) -> some View {
        if case .grid = model.screen {
            detail.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            VStack(spacing: 0) {
                LibraryNotices(model: model)
                detail.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
    }

    @ToolbarContentBuilder
    private var libraryToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: model.title).font(.headline)
                Text(verbatim: model.subtitle).font(.caption).foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
        }
        .hiddenSharedBackground()
        ToolbarItem(placement: .status) {
            if model.isOffline { OfflinePill() }
        }
        if #available(macOS 26, *) {
            ToolbarSpacer(.flexible)
        } else {
            ToolbarItem(placement: .automatic) { Spacer() }
        }
        ToolbarItem(placement: .primaryAction) {
            HStack(spacing: 12) {
                Button("Add Games", systemImage: "plus") { model.showAddGames = true }
                    .labelStyle(.iconOnly)
                    .buttonStyle(RoundGlassStyle(size: 32))
                    .help(Text("Add a Windows game or your own console games"))
                LibrarySearchField(text: $model.searchText, focused: $searchFocused)
                    .frame(height: 28)
                    .padding(.horizontal, 4)
                    .frame(width: WindowLayout(width: width, sidebar: model.showSidebar).panel, height: 32)
                    .capsuleField()
            }
        }
        .hiddenSharedBackground()
    }

    @ViewBuilder
    private var detail: some View {
        switch model.screen {
        case .loading:
            LoadingGrid()
        case .welcome:
            WelcomeView(choose: { model.selection = $0 }, addInstaller: { model.showAddGames = true })
        case .steamInstall:
            SteamInstallView(setup: steamSetup, locate: SteamInstallView.chooseSteam) {
                NSWorkspace.shared.open(SupportPaths.Steam.app)
            }
        case .signIn(let source):
            SignInView(source: source)
        case .grid(let sections):
            LibraryGrid(model: model, sections: sections, actions: actions, compat: compat)
        case .noResults(let query):
            NoResultsView(query: query) { model.searchText = "" }
        case .emptyFavorites, .emptySource:
            EmptyLibraryView(screen: model.screen, addGames: {
                model.showAddGames = true
            }, retry: { Task { await model.load() } })
        }
    }
}

struct LibraryNotices: View {
    let model: LibraryModel
    @Environment(CrashReportCenter.self) private var crashReports: CrashReportCenter?

    var body: some View {
        VStack(spacing: 0) {
            if let crashReports { CrashNoticeBanner(center: crashReports) }
            SteamIntegrationBanner()
            ProblemBanner(model: model)
        }
        .padding(.horizontal, Glass.inset)
    }
}

private extension ToolbarContent {
    func hiddenSharedBackground() -> some ToolbarContent {
        if #available(macOS 26, *) {
            return sharedBackgroundVisibility(.hidden)
        } else {
            return self
        }
    }
}

private struct OfflinePill: View {
    var body: some View {
        Label("Offline", systemImage: "wifi.slash")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.orange)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Color.orange.opacity(0.16), in: .capsule)
            .help(Text("Covers and compatibility data come from this Mac until the connection is back."))
    }
}

private struct LibrarySearchField: NSViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = String(localized: "Search")
        field.setAccessibilityLabel(String(localized: "Search"))
        field.sendsSearchStringImmediately = true
        field.controlSize = .large
        field.bezelStyle = .roundedBezel
        field.isBezeled = true
        field.drawsBackground = false
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        if focused, field.currentEditor() == nil {
            field.window?.makeFirstResponder(field)
        }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: LibrarySearchField

        init(_ parent: LibrarySearchField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            parent.focused = false
        }
    }
}

// How the window shares its width: the sidebar and the panel scale with it inside their limits,
// and the panel docks only while the grid keeps three columns beside it
struct WindowLayout: Equatable {
    let width: CGFloat
    var sidebarShown = true

    init(width: CGFloat, sidebar: Bool) {
        self.width = width
        sidebarShown = sidebar
    }

    var sidebar: CGFloat { sidebarShown ? min(260, max(200, (width * 0.167).rounded())) : 0 }
    var panel: CGFloat { min(400, max(300, (width * 0.278).rounded())) }

    // Two 132 pt columns, their gap and the grid's insets
    static let gridMinimum: CGFloat = 2 * 132 + 16 + 28 + 2 * Glass.inset

    var docksPanel: Bool {
        width - (sidebar > 0 ? sidebar + Glass.inset * 2 : 0) - (panel + Glass.inset * 2) >= Self.gridMinimum
    }
}

struct ConsoleImportSheet: View {
    var back: (@MainActor () -> Void)?
    @Environment(ConsoleCenter.self) private var consoles: ConsoleCenter?

    var body: some View {
        Group {
            if let consoles {
                ConsoleImportFlow(center: consoles, back: back)
            } else {
                ContentUnavailableView {
                    Label { Text("Add Games") } icon: { Image(systemName: "shippingbox") }
                } description: {
                    Text("Consoles are not set up on this Mac.")
                }
            }
        }
        .frame(width: 560)
    }
}
