// How the library window hosts the install sheet: Add Games for Windows opens
// it, and every finished install shows up under Windows Installers.

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

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $center.isSheetPresented) { InstallSheet(center: center) }
            .onChange(of: library.addGames) {
                // The Windows kind is this sheet; consoles keep the Add Games sheet.
                if library.addGames == .windows {
                    library.addGames = nil
                    center.open()
                }
            }
            .task {
                // Matches use the data the library already loaded.
                center.compat = { [compat] in compat.data }
                center.onGameReady = { _ in library.showInstalledGames(InstalledGames.all()) }
                center.showConsoleGames = {
                    center.isSheetPresented = false
                    Task {
                        try? await Task.sleep(for: .milliseconds(350))
                        library.addGames = .consoles
                    }
                }
                library.showInstalledGames(InstalledGames.all())
            }
    }
}

extension Binding where Value == AddGamesKind? {
    // The Add Games sheet without the Windows kind, which opens the install sheet instead.
    var withoutWindows: Binding<AddGamesKind?> {
        Binding(get: { wrappedValue == .windows ? nil : wrappedValue }, set: { wrappedValue = $0 })
    }
}

extension LibraryModel {

    // Replaces the Windows installer entries; console games stay as they are.
    func showInstalledGames(_ games: [InstalledGame]) {
        otherGames.removeAll { $0.source == .installer }
        otherGames += games.map(Game.init(installed:))
    }
}

extension Game {
    init(installed game: InstalledGame) {
        self.init(id: "installer:\(game.id)", source: .installer, name: game.name, steamAppID: game.appID,
                  installed: true, executable: game.exeURL)
    }
}
