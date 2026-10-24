import SwiftUI

struct StatusItemMenu: View {
    let model: LibraryModel
    let actions: GameActionRunner
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
        Button("Open Cartouche") {
            openWindow(id: CartoucheApp.mainWindow)
            NSApp.activate()
        }
        SwiftUI.SettingsLink { Text("Settings…") }
        Divider()
        Button("Quit Cartouche") { NSApp.terminate(nil) }
    }
}
