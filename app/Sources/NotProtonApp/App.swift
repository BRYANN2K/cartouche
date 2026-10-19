// Self-explanatory

import Network
import RetroArchKit
import SwiftUI

struct CartoucheApp: App {

    static let mainWindow = "main"
    static let setupWindow = "setup"
    static let signInWindow = "store-sign-in"

    @State private var status = SystemStatus()
    @State private var prefixes = PrefixesModel()
    @State private var pane: Pane = .status
    @State private var library: LibraryModel
    @State private var compat = CompatibilityModel()
    @State private var steamSetup = SteamSetup()
    @State private var permissions: PermissionCenter
    // Hosts the explanation that comes before the notifications prompt (P17)
    @State private var permissionFlow: PermissionFlow
    @State private var controls: ControlsCenter
    @State private var consoles: ConsolesSettingsModel
    @State private var consoleCenter: ConsoleCenter
    @State private var network = NetworkWatch()
    @State private var gameFolders = GameFolders()
    @State private var relaunch = RelaunchService()
    @State private var onboarding: OnboardingModel?
    @State private var performance = PerformanceModel()
    // The free runners and the Game Porting Toolkit, for Settings > Compatibility (P2)
    @State private var runners: RunnersModel
    // Epic, GOG and Amazon (P10)
    @State private var stores: StoreCenter
    @State private var agents: AgentControlModel
    @AppStorage(GeneralSettings.showInMenuBarKey) private var showInMenuBar = true
    @AppStorage(AfterLaunch.key) private var afterLaunch = AfterLaunch.hide
    private let updater = AppUpdater()
    private let agentBackend: AgentLiveBackend

    init() {
        // The first launch claims Cartouche's own folder, even before anything is installed
        try? FileManager.default.createDirectory(at: SupportPaths.support, withIntermediateDirectories: true)
        AppLog.start()
        if let qa = QAEnvironment.base { AppLog.note("QA mode: network base URLs re-point to \(qa.absoluteString)") }
        let permissions = PermissionCenter.live()
        _permissions = State(initialValue: permissions)
        _permissionFlow = State(initialValue: PermissionFlow(center: permissions))
        let library = LibraryModel()
        // Controllers, layouts and the options that need a permission (P15)
        let controls = ControlsCenter(
            permissions: permissions, files: ControlsFiles(retroArch: SettingsWindow.retroArchPaths))
        _controls = State(initialValue: controls)
        // Settings > Consoles and the library share one core manager
        let cores = CoreManager(paths: SettingsWindow.retroArchPaths, source: .qa)
        let consoles = SettingsWindow.consolesModel(cores: cores)
        let consoleCenter = ConsoleCenter(settings: consoles, cores: cores, library: library)
        let compat = CompatibilityModel()
        let runners = RunnersModel()
        runners.chooseToolkitFolder = ToolkitFolderPicker.choose
        _runners = State(initialValue: runners)
        _library = State(initialValue: library)
        _consoles = State(initialValue: consoles)
        _consoleCenter = State(initialValue: consoleCenter)
        _compat = State(initialValue: compat)
        _stores = State(initialValue: StoreCenter.live(library: library))
        // The agent server reads the same models the windows do; off until
        // the user turns it on (Settings > Agents).
        let backend = AgentLiveBackend(library: library, consoles: consoleCenter,
                                       installs: .shared, compat: compat, controls: controls)
        agentBackend = backend
        _agents = State(initialValue: AgentControlModel(
            service: AgentService(backend: backend, providers: [AgentControls()])))
    }

    private var actions: GameActionRunner {
        GameActionRunner(
            model: library,
            showInfo: { [library] in library.showPanel = true },
            afterLaunch: { [afterLaunch] in
                switch afterLaunch {
                case .hide: NSApp.hide(nil)
                case .keepOpen: break
                case .quit: NSApp.terminate(nil)
                }
            },
            playConsole: { [consoleCenter] game in Task { await consoleCenter.play(game.id, resume: true) } },
            stores: stores)
    }

    var body: some Scene {
        Window("Cartouche", id: Self.mainWindow) {
            LibraryWindow(model: library, compat: compat, steamSetup: steamSetup, actions: actions)
                .environment(consoleCenter)
                .environment(controls)
                .controlsSheet(controls)
                .frame(minWidth: 900, minHeight: 560)
                .permissionExplanations(permissionFlow)
                .sheet(isPresented: Binding(get: { onboarding?.isPresented ?? false },
                                            set: { onboarding?.isPresented = $0 })) {
                    if let onboarding { OnboardingView(model: onboarding).interactiveDismissDisabled() }
                }
                .environment(performance)
                .environment(stores)
                .storeSignIn(stores)
                .agentApprovals(agents)
                .task { await start() }
                // Onboarding may have added consoles and game folders
                .onChange(of: onboarding?.isPresented ?? false) { _, shown in
                    if !shown { Task { await consoleCenter.reload(); await consoleCenter.scanFolders() } }
                }
                // Back from a game: its session is read in (P8)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    Task { await performance.refresh() }
                }
        }
        .defaultSize(width: 1280, height: 820)
        .commands { menus }

        Window("Steam Play Setup", id: Self.setupWindow) {
            RootView(pane: $pane)
                .environment(status)
                .environment(prefixes)
                .frame(minWidth: 720, minHeight: 460)
                .onChange(of: pane) { prefixes.forgetOutcome() }
                .onChange(of: status.snapshot?.installedRunners.map(\.id)) {
                    if prefixes.hasLoaded { Task { await prefixes.load() } }
                    Task { await loadRunners() }
                }
        }
        .defaultSize(width: 900, height: 760)

        // The store's own sign-in page (P10)
        Window("Sign In", id: Self.signInWindow) {
            StoreSignInWindow(center: stores)
        }
        .defaultSize(width: 560, height: 760)

        Settings {
            SettingsWindow(model: library, permissions: permissions, consoles: consoles)
                .environment(consoleCenter)
                .environment(runners)
                .environment(onboarding)
                .environment(gameFolders)
                .environment(stores)
                .environment(controls)
                .storeSignIn(stores)
                .environment(agents)
                // A runner set up or repaired in Settings joins game setups right away
                .onChange(of: runners.registry.runners) { _, _ in Task { await syncRunnerList() } }
        }

        MenuBarExtra(isInserted: $showInMenuBar) {
            StatusItemMenu(model: library, actions: actions)
        } label: {
            if NSImage(named: "MenuBarGlyph") != nil {
                Image("MenuBarGlyph")
            } else {
                Image(systemName: "gamecontroller")
            }
        }
    }

    private func start() async {
        var route: ScreenRoute?
        if onboarding == nil {
            // Before anything else: a copy outside Applications offers to move and relaunch
            guard MoveToApplications.check() else { return }
            let model = makeOnboarding()
            onboarding = model
            route = relaunch.restore()
            if let route, route.screen == "onboarding" {
                model.reopen(on: route)
            } else {
                model.presentIfDue()
            }
        }
        steamSetup.onInstalled = { [library] in Task { await library.load() } }
        network.start { [library] offline in library.isOffline = offline }
        compat.load()
        await library.load()
        library.watch()
        await consoleCenter.reload()
        // A console session left over when Cartouche was killed is picked up or counted
        await consoleCenter.reattachOrphaned()
        consoleCenter.folderList = gameFolders
        consoleCenter.netplayFlow = PermissionFlow(center: permissions)
        await consoleCenter.startWatching()
        controls.couch.play = { [actions] game in actions.perform(game.installed ? .play : .install, on: game) }
        await controls.start(relaunch: relaunch, library: library)
        // A relaunch for Input Monitoring reopens the same game's Controls
        if let route, route.screen == "controls" { await controls.reopen(route) }
        // A console game still running when Cartouche quits is quit and counted first
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) {
            [consoleCenter] _ in MainActor.assumeIsolated { consoleCenter.endForTermination() }
        }
        await startActivity()
        await loadRunners()
        startStores()
        await compat.refresh()
        // With the library and folders loaded the agent's readable roots are known
        agentBackend.refreshRoots()
    }

    // Store accounts from the Keychain, then each store's list in the background (P10)
    private func startStores() {
        stores.afterLaunch = actions.afterLaunch
        let index = TitleIndex()
        stores.matchAppID = { [compat] title in index.appID(title, data: compat.data) }
        // The store's running job joins the shared activity slot (P7)
        let activity = ActivityCenter.shared
        activity.storeSource = { [stores] in stores.activity }
        activity.stopStore = { [stores] in stores.stop($0) }
        Task { await stores.start(refresh: !library.isOffline) }
    }

    // The activity slot: Steam's downloads and running game, and the first finished
    // download or install offers notifications (P7, P17)
    private func startActivity() async {
        RevealRenderer.warmUp()
        await permissions.refresh(.notifications)
        let activity = ActivityCenter.shared
        activity.permissionFlow = permissionFlow
        InstallCenter.shared.permissionFlow = permissionFlow
        activity.follow(consoleCenter)
        activity.onDownloadFinished = { [library] _ in Task { await library.load() } }
        activity.watch()
    }

    private func makeOnboarding() -> OnboardingModel {
        relaunch.center = permissions
        let step = SteamStep(
            flow: PermissionFlow(center: permissions),
            install: { try await OnboardingSteam.install() },
            relaunch: { [relaunch] route in Task { await relaunch.relaunch(to: route) } })
        let model = OnboardingModel(
            consoles: .live(paths: consoles.paths), steamStep: step, folders: gameFolders,
            privacy: compat.choices, library: library)
        model.play = { [actions] game in actions.perform(.play, on: game) }
        return model
    }

    // Runners are read through the registry, off the main thread — free builds and
    // the Game Porting Toolkit included, so game setups can offer them (P2, P3)
    private func loadRunners() async {
        await runners.refresh()
        await syncRunnerList()
        let (tools, platforms, mappings) = await Task.detached {
            (RunnerRegistry.backendTools(),
             SteamAppInfo.platforms(), (SteamCompatChoice.mappings(), SteamCompatChoice.modified()))
        }.value
        library.backendTools = tools
        library.macBuilds = platforms?.both ?? []
        library.adoptSteamChoices(mappings.0, written: mappings.1)
    }

    // What the Runners screen's registry knows, handed to the setups (P3)
    private func syncRunnerList() async {
        let registry = runners.registry
        let manifest = runners.manifest
        library.runners = registry.runners
        library.backendAvailability = await Task.detached {
            BackendAvailability.current(registry: registry, manifest: manifest)
        }.value
    }

    @CommandsBuilder
    private var menus: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Add Games…") { library.addGames = .windows }
                .keyboardShortcut("o", modifiers: .command)
        }

        CommandGroup(replacing: .appInfo) {
            Button("About Cartouche") { Attribution.showAboutPanel() }
        }

        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { updater.check() }
        }

        CommandGroup(replacing: .textEditing) {
            Button("Find") { library.searchFocusRequests += 1 }
                .keyboardShortcut("f", modifiers: .command)
        }

        CommandGroup(after: .sidebar) {
            Toggle("Show Games That Are Not Installed", isOn: $library.showNotInstalled)
            Button(library.showPanel ? "Hide Game Panel" : "Show Game Panel") { library.showPanel.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
            Divider()
            Button("Refresh Library") { Task { await library.load() } }
                .keyboardShortcut("r", modifiers: .command)
            Divider()
        }

        CommandMenu("Game") {
            GameCommands(model: library, actions: actions)
        }

        CommandMenu("Setup") {
            SetupWindowButton(title: String(localized: "Steam Play Setup"))
            SetupWindowButton(title: String(localized: "Status"), pane: .status, select: { pane = $0 })
                .keyboardShortcut("1", modifiers: .command)
            SetupWindowButton(title: String(localized: "Prefixes"), pane: .prefixes, select: { pane = $0 })
                .keyboardShortcut("2", modifiers: .command)
            SetupWindowButton(title: String(localized: "Prefix Backups"), pane: .backups, select: { pane = $0 })
                .keyboardShortcut("3", modifiers: .command)

            Button("Refresh Setup") {
                Task {
                    switch pane {
                    case .status: await status.refresh()
                    case .prefixes, .backups: await prefixes.load()
                    }
                }
            }
            .disabled(pane == .status ? !status.isIdle : prefixes.isLoading)

            Divider()

            Button("Install") { Task { await status.requestInstall() } }
                .disabled(!status.canInstall)

            Button("Set Up Compatibility Tool") { Task { await status.requestCompatibilityTool() } }
                .disabled(!status.canInstall || status.setupSource == nil)

            Button("Fetch Valve Binaries") { Task { await status.fetchValveBinaries() } }
                .disabled(!status.canInstall)

            Divider()

            updateBlockCommand

            Button("Repair Steam") { status.pendingConfirmation = .replaceSteam }
                .disabled(!status.isIdle)

            Divider()

            Button("Reveal Log in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([AppLog.file])
            }
        }

        prefixMenu
    }

    @CommandsBuilder
    private var prefixMenu: some Commands {
        CommandMenu("Prefix") {
            Button("Run Program…") {
                if let prefix = prefixTarget { prefixes.chooseExecutable(for: prefix) }
            }
            .disabled(prefixTarget == nil)

            Divider()

            ForEach(WineTool.allCases, id: \.self) { tool in
                Button(tool.label) {
                    if let prefix = prefixes.selectedPrefix { prefixes.open(tool, for: prefix) }
                }
                .disabled(prefixTarget == nil)
            }

            Divider()

            Button("Reveal in Finder") {
                if let prefix = prefixes.selectedPrefix { prefixes.reveal(prefix) }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(prefixes.selectedPrefix == nil)

            Divider()

            Button(PrefixPrompt.backUpButton(selectionTargets)) {
                if !selectionTargets.isEmpty {
                    prefixes.pendingConfirmation = .backUp(selectionTargets)
                }
            }
            .disabled(selectionTargets.isEmpty)

            if prefixes.tools.count > 1 {
                Menu(PrefixPrompt.rebuildButton(selectionTargets)) {
                    ForEach(prefixes.tools) { tool in
                        Button(tool.display) {
                            prefixes.pendingConfirmation = .rebuild(selectionTargets, tool)
                        }
                    }
                }
                .disabled(selectionTargets.isEmpty)
            } else {
                Button(PrefixPrompt.rebuildButton(selectionTargets)) {
                    if let tool = prefixes.tools.first, !selectionTargets.isEmpty {
                        prefixes.pendingConfirmation = .rebuild(selectionTargets, tool)
                    }
                }
                .disabled(selectionTargets.isEmpty || prefixes.tools.isEmpty)
            }

            Button(PrefixPrompt.deleteButton(selectionTargets)) {
                if !selectionTargets.isEmpty {
                    prefixes.pendingConfirmation = .delete(selectionTargets)
                }
            }
            .disabled(selectionTargets.isEmpty)
        }
    }

    private var prefixTarget: WinePrefix? {
        prefixes.isBusy ? nil : prefixes.selectedPrefix
    }

    private var selectionTargets: [WinePrefix] {
        prefixes.isBusy ? [] : prefixes.selectedPrefixes
    }

    @ViewBuilder
    private var updateBlockCommand: some View {
        if status.snapshot?.updateBlocked == true {
            Button("Allow Client Updates") { Task { await status.setUpdateBlock(false) } }
                .disabled(!status.isIdle)
        } else {
            Button("Block Client Updates") { status.pendingConfirmation = .blockUpdates }
                .disabled(!status.isIdle || status.snapshot == nil)
        }
    }
}

// The Game menu: the selected game's menu, the same list as its context menu
struct GameCommands: View {
    let model: LibraryModel
    let actions: GameActionRunner

    var body: some View {
        if let game = model.selectedGame, model.screen.showsPanel {
            GameMenuContent(items: GameMenu.items(for: game, in: model)) { actions.perform($0, on: game) }
        } else {
            Button("Play") {}.shortcut(GameMenu.play).disabled(true)
            Divider()
            Button("Add to Favorites") {}.shortcut(GameMenu.favorite).disabled(true)
            Button("Get Info") {}.shortcut(GameMenu.getInfo).disabled(true)
        }
    }
}

struct SetupWindowButton: View {
    let title: String
    var pane: Pane?
    var select: (Pane) -> Void = { _ in }
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(title) {
            if let pane { select(pane) }
            openWindow(id: CartoucheApp.setupWindow)
        }
    }
}

struct StatusItemMenu: View {
    let model: LibraryModel
    let actions: GameActionRunner
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // Everything going on, even what the sidebar slot leaves out (P7)
        ActivityMenuContent(center: ActivityCenter.shared)
        let recent = model.recentlyPlayed
        if !recent.isEmpty {
            Section("Recently Played") {
                ForEach(recent) { game in
                    Button(game.name) { actions.perform(.play, on: game) }
                }
            }
            Divider()
        }
        Button("Open Cartouche") {
            openWindow(id: CartoucheApp.mainWindow)
            NSApp.activate()
        }
        SwiftUI.SettingsLink { Text("Settings…") }
        Divider()
        Button("Quit Cartouche") { NSApp.terminate(nil) }
    }
}

// Online or not, as macOS sees the network path
@MainActor
final class NetworkWatch {
    private let monitor = NWPathMonitor()

    func start(_ changed: @escaping @MainActor (Bool) -> Void) {
        monitor.pathUpdateHandler = { path in
            let offline = path.status != .satisfied
            Task { @MainActor in changed(offline) }
        }
        monitor.start(queue: DispatchQueue(label: "cartouche.network"))
    }
}
