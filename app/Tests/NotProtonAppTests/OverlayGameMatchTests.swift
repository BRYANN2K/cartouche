import Foundation
import Testing
@testable import NotProtonApp

// The menu's title for a Steam launch is the library's name, « Deadlock », never « deadlock.exe »
@Suite("Overlay game match")
struct OverlayGameMatchTests {
    let deadlock = Game.steam(1_422_450, name: "Deadlock", installed: true)
    let other = Game.steam(730, name: "Counter-Strike 2", installed: true)
    var games: [Game] { [other, deadlock] }

    func folder(_ game: Game) -> URL? {
        URL(filePath: "/Users/me/Library/Application Support/Steam/steamapps/common/\(game.name)")
    }

    @Test("The exe's name alone finds the game")
    func byName() {
        #expect(OverlayGameMatch.match(name: "deadlock.exe", appID: nil, exe: nil, playingID: nil, games: games, folder: folder) == deadlock)
        #expect(OverlayGameMatch.match(name: "unknown.exe", appID: nil, exe: nil, playingID: nil, games: games, folder: folder) == nil)
    }

    @Test("Steam's app ID first, then the exe's folder, then the game Cartouche launched")
    func order() {
        #expect(OverlayGameMatch.match(name: "project8.exe", appID: 1_422_450, exe: nil, playingID: nil, games: games, folder: folder) == deadlock)
        let exe = "/Users/me/Library/Application Support/Steam/steamapps/common/Deadlock/game/bin/win64/project8.exe"
        #expect(OverlayGameMatch.match(name: "project8.exe", appID: nil, exe: exe, playingID: nil, games: games, folder: folder) == deadlock)
        #expect(OverlayGameMatch.match(name: "project8.exe", appID: nil, exe: nil, playingID: "steam:1422450", games: games, folder: folder) == deadlock)
        let sibling = "/Users/me/Library/Application Support/Steam/steamapps/common/Deadlock Tools/x.exe"
        #expect(OverlayGameMatch.match(name: "x.exe", appID: nil, exe: sibling, playingID: nil, games: games, folder: folder) == nil)
    }

    @Test("Unmatched, the title drops « .exe »; Steam's variables carry the app ID")
    func display() {
        #expect(OverlayGameMatch.displayName("deadlock.exe") == "deadlock")
        #expect(OverlayGameMatch.displayName("Deadlock") == "Deadlock")
        #expect(OverlayGameMatch.steamAppID(["SteamAppId": "1422450"]) == 1_422_450)
        #expect(OverlayGameMatch.steamAppID(["SteamGameId": "730"]) == 730)
        #expect(OverlayGameMatch.steamAppID([:]) == nil)
    }
}
