
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
            .sheet(isPresented: $center.isSheetPresented, onDismiss: { center.sheetDismissed() }) {
                InstallSheet(center: center)
            }
            .task {
                center.compat = { [compat] in compat.data }
                center.lookupsAllowed = { [compat] in compat.choices.fetchMacReports }
                center.onGameReady = { _ in
                    Task {
                        await library.reloadInstalledGames()
                        await library.resolveInstallerAppIDs(lookup: center.lookup, allowed: compat.choices.fetchMacReports)
                    }
                }
                library.onGamesLocationChange = { [center] in center.engine.installs = $0 }
                await library.reloadInstalledGames(forgetUnused: true)
                center.refreshBusy(for: library.allGames, in: library.installsFolder)
                Task {
                    // Games extracted before drops moved out of Caches move now, off the main actor.
                    let installs = library.installsFolder
                    let moved = await Task.detached { StagedGames.migrate(installs: installs) }.value
                    if !moved.isEmpty { await library.reloadInstalledGames() }
                    // Older records can still hold a raw folder name: the pipeline names
                    // them once, then the Steam pass fills any app ID still missing.
                    let allowed = compat.choices.fetchMacReports
                    await library.reidentifyInstalledGames(
                        index: await center.titles.index(for: await center.compat()),
                        lookup: center.lookup, allowed: allowed)
                    await library.resolveInstallerAppIDs(lookup: center.lookup, allowed: allowed)
                }
            }
    }
}

extension LibraryModel {

    func showInstalledGames(_ games: [InstalledGame]) {
        otherGames.removeAll { $0.source == .installer }
        otherGames += games.map(Game.init(installed:))
        refreshExeOptions(for: otherGames.filter { $0.source == .installer })
    }
}

extension Game {
    init(installed game: InstalledGame) {
        self.init(id: "installer:\(game.id)", source: .installer, name: game.name, steamAppID: game.appID,
                  installed: true, executable: game.exeURL,
                  installRunnerID: game.runnerID, installGraphics: game.backend)
    }
}
