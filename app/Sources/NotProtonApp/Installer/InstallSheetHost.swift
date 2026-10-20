
import SwiftUI

extension View {
    func installSheet(library: LibraryModel, compat: CompatibilityModel, center: InstallCenter = .shared) -> some View {
        modifier(InstallSheetHost(library: library, compat: compat, center: center))
    }
}

private struct InstallSheetHost: ViewModifier {
    let library: LibraryModel
    let compat: CompatibilityModel
    @Bindable var center: InstallCenter
    @State private var pendingConsoles = false

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $center.isSheetPresented, onDismiss: {
                if pendingConsoles {
                    pendingConsoles = false
                    library.addGames = .consoles
                }
            }) { InstallSheet(center: center) }
            .onChange(of: library.addGames) {
                if library.addGames == .windows {
                    library.addGames = nil
                    center.open()
                }
            }
            .task {
                center.compat = { [compat] in compat.data }
                center.onGameReady = { _ in library.showInstalledGames(InstalledGames.all()) }
                center.showConsoleGames = {
                    center.isSheetPresented = false
                    pendingConsoles = true
                }
                library.showInstalledGames(InstalledGames.all())
            }
    }
}

extension Binding where Value == AddGamesKind? {
    var withoutWindows: Binding<AddGamesKind?> {
        Binding(get: { wrappedValue == .windows ? nil : wrappedValue }, set: { wrappedValue = $0 })
    }
}

extension LibraryModel {

    func showInstalledGames(_ games: [InstalledGame]) {
        otherGames.removeAll { $0.source == .installer }
        otherGames += games.map(Game.init(installed:))
    }
}

extension Game {
    init(installed game: InstalledGame) {
        self.init(id: "installer:\(game.id)", source: .installer, name: game.name, steamAppID: game.appID,
                  installed: true, executable: game.exeURL,
                  installRunnerID: game.runnerID, installGraphics: game.backend)
    }
}
