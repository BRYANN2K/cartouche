import Foundation
import Testing

@testable import NotProtonApp

@Suite("Add Games and the flows it opens")
@MainActor
struct AddGamesNavigationTests {

    private func droppedGame() throws -> (DropModel, DroppedInstalledGame) {
        guard case .installedGame(let game) = DropFixtures.installedGame else { throw CancellationError() }
        let drop = DropModel()
        drop.show(DropFixtures.installedGame)
        drop.chosenExe = game.executables[1]
        drop.storage = .copy
        return (drop, game)
    }

    @Test("A flow opened from the drop sheet runs once the sheet is gone, and Back brings the drop back as it was")
    func handOffAndBack() throws {
        let nav = AddGamesNavigation()
        let (drop, game) = try droppedGame()
        nav.drop = drop
        let opened = Box(0)
        nav.handOff { opened.value += 1 }
        #expect(opened.value == 0)
        nav.sheetDismissed()
        #expect(opened.value == 1)
        #expect(nav.drop == nil)
        #expect(nav.canReturn)

        #expect(nav.restore())
        #expect(nav.drop === drop)
        #expect(drop.phase == .result(DropFixtures.installedGame))
        #expect(drop.chosenExe == game.executables[1])
        #expect(drop.storage == .copy)
        #expect(!nav.canReturn)
        #expect(!nav.restore())
    }

    @Test("Closing Add Games without a flow cancels its drop and forgets any earlier one")
    func plainDismiss() throws {
        let nav = AddGamesNavigation()
        let (first, _) = try droppedGame()
        nav.drop = first
        nav.handOff {}
        nav.sheetDismissed()
        #expect(nav.restore())
        nav.sheetDismissed()
        #expect(first.phase == nil)
        #expect(!nav.canReturn)

        let (second, _) = try droppedGame()
        nav.drop = second
        nav.handOff {}
        nav.sheetDismissed()
        nav.drop = DropModel()
        nav.sheetDismissed()
        #expect(!nav.canReturn)
        #expect(nav.drop == nil)
    }

    @Test("The console flow's Back shows Add Games again once its sheet is gone; Add or Cancel does not")
    func consoleBack() throws {
        let nav = AddGamesNavigation()
        let (drop, _) = try droppedGame()
        nav.drop = drop
        nav.handOff {}
        nav.sheetDismissed()

        // Closed by Add or Cancel
        #expect(!nav.flowDismissed())
        #expect(nav.canReturn)

        nav.returnOnDismiss()
        #expect(nav.flowDismissed())
        #expect(nav.drop === drop)
        #expect(!nav.flowDismissed())
    }

    @Test("Back from a flow with nothing to return to does nothing")
    func nothingParked() {
        let nav = AddGamesNavigation()
        nav.returnOnDismiss()
        #expect(!nav.flowDismissed())
        #expect(nav.drop == nil)
    }
}
