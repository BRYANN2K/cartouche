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

    @FocusState private var searchFocused: Bool
    @State private var width: CGFloat = 1280
    @State private var overlayDismissedFor: String?
    @State private var dropTargeted = false
    @State private var drop: DropModel?
    @State private var afterDropDismiss: (@MainActor () -> Void)?
    @Environment(\.dropClassifier) private var dropClassifier
    @Environment(\.gameVerification) private var verification
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.activity) private var activity
    @Environment(ConsoleCenter.self) private var consoles: ConsoleCenter?
    @Environment(CrashReportCenter.self) private var crashReports: CrashReportCenter?

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
        .overlay { DropOverlay(targeted: dropTargeted) }
        .dropDestination(for: URL.self) { urls, _ in
            handleDrop(urls)
        } isTargeted: { dropTargeted = $0 }
        .background {
            CoverBackdrop(game: backdropGame,
                          override: backdropGame.flatMap { model.coverOverride(for: $0.id) })
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
        .ignoresSafeArea()
        .scrollBounceBehavior(.basedOnSize, axes: [.vertical, .horizontal])
        .animation(motion.panel, value: floating)
        .animation(motion.panel, value: layout.sidebar > 0)
        .transaction(value: model.selection) { $0.animation = nil }
        .windowChrome()
        .navigationTitle(model.title)
        .navigationSubtitle(model.subtitle)
        .onChange(of: model.searchFocusRequests) { searchFocused = true }
        .onChange(of: layout.docksPanel) { _, docks in
            // Going narrow keeps the grid in view; the panel comes back when a game is picked
            if !docks { overlayDismissedFor = model.selectedGameID }
        }
        .sheet(item: $model.addGames.withoutWindows) { kind in
            AddGamesSheet(kind: kind, library: model)
        }
        .sheet(isPresented: $model.showAddGames, onDismiss: {
            drop?.cancel()
            drop = nil
            let action = afterDropDismiss
            afterDropDismiss = nil
            action?()
        }) {
            if let drop {
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
            drop = next
            next.start(urls)
        } else {
            let next = DropModel()
            next.show(.failed(.detectionUnavailable))
            drop = next
        }
        model.showAddGames = true
        return true
    }

    private var dropActions: DropActions {
        var actions = DropActions()
        actions.install = { installer in
            afterDropDismiss = { InstallCenter.shared.open([installer.setup]) }
            model.showAddGames = false
        }
        actions.importGame = { game, _, _ in
            afterDropDismiss = { InstallCenter.shared.open([game.folder]) }
            model.showAddGames = false
        }
        actions.addROMs = { roms in
            guard let consoles else { return }
            afterDropDismiss = {
                consoles.importFlow.start(roms.groups.flatMap(\.files))
                model.addGames = .consoles
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
            // Room for the window's traffic lights, which sit inside the panel
            .padding(.top, 44)
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
            .floatingPanel()
            .padding([.top, .bottom, .trailing], Glass.inset)
    }

    private func main(_ layout: WindowLayout) -> some View {
        VStack(spacing: 0) {
            SteamIntegrationBanner()
                .padding(.horizontal, Glass.inset)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let crashReports { CrashNoticeBanner(center: crashReports) }
        }
        .toolbarBar { toolbar(layout) }
    }

    private func toolbar(_ layout: WindowLayout) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: model.title)
                    .font(.system(size: 15, weight: .bold))
                    .tracking(-0.15)
                Text(verbatim: model.subtitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Glass.label2)
            }
            .lineLimit(1)
            .fixedSize()
            .layoutPriority(1)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            if model.isOffline {
                OfflinePill()
            }
            SearchCapsule(text: $model.searchText, isFocused: $searchFocused)
            AddGamesButton(model: model)
        }
        // With the sidebar hidden the title clears the traffic lights
        .padding(.leading, layout.sidebar > 0 ? 12 : 84)
        .padding(.trailing, 14)
        .frame(height: Glass.toolbarHeight)
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

private extension View {
    // A window toolbar with nothing in it: it only gives the traffic lights the tall title bar's
    // position inside the sidebar panel; the real toolbar is drawn over the content column
    func windowChrome() -> some View {
        toolbar {
            ToolbarItem(placement: .automatic) {
                Color.clear.frame(width: 1, height: 1).accessibilityHidden(true)
            }
            .hiddenSharedBackground()
        }
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    }

    // The toolbar row floats on the backdrop; content scrolls under it behind a soft edge fade
    @ViewBuilder
    func toolbarBar<Bar: View>(@ViewBuilder _ bar: () -> Bar) -> some View {
        if #available(macOS 26, *) {
            safeAreaInset(edge: .top, spacing: 0, content: bar)
                .scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            safeAreaInset(edge: .top, spacing: 0, content: bar)
        }
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

// The toolbar search field: a wide glass capsule with a magnifier and a "Search" placeholder
private struct SearchCapsule: View {
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Glass.label3)
                .accessibilityHidden(true)
            TextField("Search", text: $text, prompt: Text("Search").foregroundStyle(Glass.label3))
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused(isFocused)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Glass.label3)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Clear Search"))
            }
        }
        .padding(.horizontal, 12)
        .frame(minWidth: 34, idealWidth: 230, maxWidth: 230)
        .frame(height: 34)
        .capsuleField()
        .contentShape(.capsule)
        .onTapGesture { isFocused.wrappedValue = true }
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

// The round glass "+" paired with the search capsule, the user's take on the mockup's Add Games pill
private struct AddGamesButton: View {
    let model: LibraryModel

    var body: some View {
        Button {
            model.showAddGames = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 15, weight: .semibold))
        }
        .buttonStyle(RoundGlassStyle())
        .fixedSize()
        .help(Text("Add a Windows game or your own console games"))
        .accessibilityLabel(Text("Add Games"))
    }
}

struct AddGamesSheet: View {
    @State var kind: AddGamesKind
    let library: LibraryModel
    @Environment(ConsoleCenter.self) private var consoles: ConsoleCenter?

    var body: some View {
        Group {
            if let consoles {
                ConsoleImportFlow(center: consoles, kind: $kind)
            } else {
                ContentUnavailableView {
                    Label { Text("Add Games") } icon: { Image(systemName: "shippingbox") }
                } description: {
                    Text("Consoles are not set up on this Mac.")
                }
            }
        }
        .onChange(of: kind, initial: true) { _, kind in
            if kind == .windows { library.addGames = .windows }
        }
        .frame(width: 560)
    }
}
