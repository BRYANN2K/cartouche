import SwiftUI

extension CartoucheApp {

    @CommandsBuilder
    var menus: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Add Games…") { library.showAddGames = true }
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
            Button(library.showSidebar ? "Hide Sidebar" : "Show Sidebar") { library.showSidebar.toggle() }
                .keyboardShortcut("s", modifiers: [.control, .command])
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

struct GameCommands: View {
    let model: LibraryModel
    let actions: GameActionRunner
    @Environment(StoreCenter.self) private var stores: StoreCenter?

    var body: some View {
        if let game = model.selectedGame, model.screen.showsPanel {
            GameMenuContent(items: GameMenu.items(for: game, in: model, stores: stores)) { actions.perform($0, on: game) }
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
