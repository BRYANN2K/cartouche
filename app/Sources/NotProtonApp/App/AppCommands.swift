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

        CommandGroup(replacing: .help) {
            Menu("Troubleshooting") {
                Button("Refresh Steam Status") { Task { await status.refresh() } }
                    .disabled(!status.isIdle)
                Button("Reveal Log in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([AppLog.file])
                }
            }
        }
    }
}

struct GameCommands: View {
    let model: LibraryModel
    let actions: GameActionRunner
    @Environment(ConsoleCenter.self) private var consoles: ConsoleCenter?
    @Environment(StoreCenter.self) private var stores: StoreCenter?

    var body: some View {
        if let game = model.selectedGame, model.screen.showsPanel {
            GameMenuContent(items: GameMenu.items(for: game, in: model, stores: stores, consoles: consoles)) { actions.perform($0, on: game) }
        } else {
            Button("Play") {}.shortcut(GameMenu.play).disabled(true)
            Divider()
            Button("Add to Favorites") {}.shortcut(GameMenu.favorite).disabled(true)
            Button("Get Info") {}.shortcut(GameMenu.getInfo).disabled(true)
        }
    }
}
