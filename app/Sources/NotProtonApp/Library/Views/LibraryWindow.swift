import SwiftUI

struct LibrarySidebar: View {
    @Bindable var model: LibraryModel
    @Environment(ConsoleCenter.self) private var consoles: ConsoleCenter?

    var body: some View {
        List(selection: $model.selection) {
            Section("Library") {
                row(.all, symbol: "square.grid.2x2")
                row(.favorites, symbol: "star")
            }
            Section("PC") {
                row(.source(.steam), symbol: "gamecontroller")
                row(.source(.epic), symbol: "bag")
                row(.source(.gog), symbol: "opticaldisc")
                row(.source(.amazon), symbol: "cart")
                row(.source(.installer), symbol: "shippingbox")
            }
            Section {
                ForEach(model.consoles, id: \.self) { id in
                    ConsoleSidebarRow(id: id, model: model)
                }
            } header: {
                HStack {
                    Text("Consoles")
                    Spacer()
                    if consoles?.downloading.isEmpty == false {
                        ProgressView().controlSize(.mini)
                            .help(Text("Downloading cores…"))
                    }
                    Button {
                        model.showAddConsoles = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .help(Text("Add Consoles"))
                    .accessibilityLabel(Text("Add Consoles"))
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
    }

    private func row(_ item: SidebarItem, symbol: String) -> some View {
        Label(LibraryModel.title(item), systemImage: symbol)
            .badge(model.badge(item).map { Text(verbatim: $0) })
            // An expired store session is a red badge
            .badgeProminence(model.isExpired(item) ? .increased : .standard)
            .tag(item)
    }
}

struct LibraryWindow: View {
    @Bindable var model: LibraryModel
    let compat: CompatibilityModel
    @Bindable var steamSetup: SteamSetup
    let actions: GameActionRunner

    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.activity) private var activity
    @Environment(ConsoleCenter.self) private var consoles: ConsoleCenter?

    var body: some View {
        NavigationSplitView {
            LibrarySidebar(model: model)
                .activitySlot(activity, library: model)
        } detail: {
            detail
                .inspector(isPresented: Binding(
                    get: { model.showPanel && model.screen.showsPanel && model.selectedGame != nil },
                    set: { model.showPanel = $0 })) {
                    if let game = model.selectedGame {
                        GamePanel(game: game, model: model, compat: compat, actions: actions)
                            .inspectorColumnWidth(min: 300, ideal: 340, max: 420)
                    }
                }
        }
        .navigationTitle(model.title)
        .navigationSubtitle(model.subtitle)
        .searchable(text: $model.searchText, placement: .toolbar, prompt: Text("Search"))
        .searchFocused($searchFocused)
        .onChange(of: model.searchFocusRequests) { searchFocused = true }
        .toolbar {
            if model.isOffline {
                ToolbarItem {
                    Label("Offline", systemImage: "wifi.slash")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.secondary)
                        .help(Text("Covers and compatibility data come from this Mac until the connection is back."))
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    ForEach(AddGamesKind.allCases) { kind in
                        Button(kind.title + "…") { model.addGames = kind }
                    }
                } label: {
                    Label("Add Games…", systemImage: "plus")
                        .labelStyle(.titleAndIcon)
                }
                .help(Text("Add a Windows game or your own console games"))
            }
        }
        .sheet(item: $model.addGames.withoutWindows) { kind in
            AddGamesSheet(kind: kind, library: model)
        }
        .sheet(isPresented: $model.showAddConsoles) {
            if let consoles { AddConsolesSheet(center: consoles) }
        }
        .overlay {
            if let consoles, let powerOn = consoles.powerOn, !reduceMotion {
                CRTPowerOn(powerOn: powerOn) { consoles.powerOn = nil }
            }
        }
        .installSheet(library: model, compat: compat)
        .animation(Motion(reduceMotion: reduceMotion).panel, value: model.selectedGameID)
    }

    @ViewBuilder
    private var detail: some View {
        switch model.screen {
        case .loading:
            LoadingGrid()
        case .welcome:
            WelcomeView(choose: { model.selection = $0 }, addInstaller: { model.addGames = .windows })
        case .steamInstall:
            SteamInstallView(setup: steamSetup, locate: SteamInstallView.chooseSteam) {
                NSWorkspace.shared.open(SupportPaths.Steam.app)
            }
        case .signIn(let source):
            SignInView(source: source)
        case .grid(let sections):
            LibraryGrid(model: model, sections: sections, actions: actions)
        case .noResults(let query):
            NoResultsView(query: query) { model.searchText = "" }
        case .emptyFavorites, .emptySource:
            EmptyLibraryView(screen: model.screen, addGames: {
                if case .source(let source) = model.selection, source.isConsole { model.addGames = .consoles } else { model.addGames = .windows }
            }, retry: { Task { await model.load() } })
        }
    }
}

// The Windows kind opens the install sheet instead, through InstallSheetHost.
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
            // Windows installers go through the install sheet, which the host
            // opens and dismisses this one for
            if kind == .windows { library.addGames = .windows }
        }
        .frame(width: 520)
    }
}
