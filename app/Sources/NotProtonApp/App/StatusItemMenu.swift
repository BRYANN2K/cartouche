import SwiftUI

struct StatusItemMenu: View {
    let model: LibraryModel
    let actions: GameActionRunner
    var resources: ResourceMonitor?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
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
        // The in-game menu without its shortcut, for when ⌥C is taken
        if OverlayController.shared.gameRunning {
            Button("In-Game Menu") { OverlayController.shared.open() }
        }
        Button("Open Cartouche") {
            openWindow(id: CartoucheApp.mainWindow)
            NSApp.activate()
        }
        if resources != nil {
            Button("Resources…") {
                openWindow(id: CartoucheApp.mainWindow)
                NSApp.activate()
                BackgroundAppsPresenter.shared.show()
            }
            .keyboardShortcut("r", modifiers: [.command, .option])
        }
        SwiftUI.SettingsLink { Text("Settings…") }
        Divider()
        Button("Quit Cartouche") { NSApp.terminate(nil) }
    }
}
