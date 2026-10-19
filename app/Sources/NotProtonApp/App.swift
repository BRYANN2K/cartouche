// Self-explanatory

import Network
import RetroArchKit
import SwiftUI

struct CartoucheApp: App {

    static let mainWindow = "main"
    static let setupWindow = "setup"

    @State private var status = SystemStatus()
    @State private var prefixes = PrefixesModel()
    @State private var pane: Pane = .status
    @State private var library = LibraryModel()
    @State private var compat = CompatibilityModel()
    @State private var steamSetup = SteamSetup()
    @State private var permissions = PermissionCenter.live()
    @State private var consoles = SettingsWindow.consolesModel()
    @State private var network = NetworkWatch()
    @AppStorage(GeneralSettings.showInMenuBarKey) private var showInMenuBar = true
    @AppStorage(AfterLaunch.key) private var afterLaunch = AfterLaunch.hide
    private let updater = AppUpdater()

    init() {
        // The first launch claims Cartouche's own folder, even before anything is installed
        try? FileManager.default.createDirectory(at: SupportPaths.support, withIntermediateDirectories: true)
        AppLog.start()
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
            })
    }

    var body: some Scene {
        Window("Cartouche", id: Self.mainWindow) {
            LibraryWindow(model: library, compat: compat, steamSetup: steamSetup, actions: actions)
                .frame(minWidth: 900, minHeight: 560)
                .task { await start() }
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

        Settings {
            SettingsWindow(model: library, permissions: permissions, consoles: consoles)
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
        steamSetup.onInstalled = { [library] in Task { await library.load() } }
        network.start { [library] offline in library.isOffline = offline }
        compat.load()
        await library.load()
        library.watch()
        await loadRunners()
        await compat.refresh()
    }

    // Runners are read through the registry, off the main thread
    private func loadRunners() async {
        let registry = await Task.detached { RunnerRegistry.refresh() }.value
        library.runners = registry.runners
        // What each runner can pair with, which games have a Mac build, and Steam's own choices (P3)
        let (availability, tools, platforms, mappings) = await Task.detached {
            (BackendAvailability.current(registry: registry), RunnerRegistry.backendTools(),
             SteamAppInfo.platforms(), (SteamCompatChoice.mappings(), SteamCompatChoice.modified()))
        }.value
        library.backendAvailability = availability
        library.backendTools = tools
        library.macBuilds = platforms?.both ?? []
        library.adoptSteamChoices(mappings.0, written: mappings.1)
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
