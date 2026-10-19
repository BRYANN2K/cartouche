import Foundation
import RetroArchKit
import SwiftUI
import Testing

@testable import NotProtonApp

// P14 in the console panel: Play Together, achievements, Hardcore, Translate
// the screen and Coach mode. RetroAchievements and the lobby are stood in for
// by recorded answers; the keychain by memory.
@Suite("Console extras in the panel", .serialized)
@MainActor
struct ConsoleExtrasPanelTests {

    static let login = #"{"Success":true,"User":"player42","Token":"Q1w2E3r4T5y6U7i8","Score":1250,"SoftcoreScore":40,"Messages":0,"Permissions":1,"AccountType":"Registered"}"#
    static let gameID = #"{"Success":true,"GameID":228}"#
    static let progress = #"{"Success":true,"Response":{"228":{"Achievements":64,"Unlocked":12,"UnlockedHardcore":7}}}"#

    // The scene's center with extras that never reach the network or the keychain
    static func signIn(_ scene: ConsoleScene) async -> MemorySecrets {
        let answers = ["login2": login, "gameid": gameID, "allprogress": progress]
        let client = AchievementsClient(host: URL(string: "https://ra.test/")!) { request in
            let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            let r = body.split(separator: "&").first { $0.hasPrefix("r=") }.map { String($0.dropFirst(2)) } ?? ""
            return (Data((answers[r] ?? #"{"Success":false,"Error":"?"}"#).utf8), 200)
        }
        let secrets = MemorySecrets()
        scene.center.extras = ConsoleExtras(paths: scene.paths, client: client, secrets: secrets,
                                            cloud: CloudSaves(paths: scene.paths, drive: scene.work.appending(path: "iCloud Drive")))
        await scene.center.extras.signIn(username: "player42", password: "correct horse")
        return secrets
    }

    private func panel(_ scene: ConsoleScene, _ id: String, compat: CompatibilityModel) throws -> some View {
        let game = try #require(scene.library.game(id))
        return GamePanel(game: game, model: scene.library, compat: compat,
                         actions: GameActionRunner(model: scene.library, open: { _ in }))
            .environment(scene.center)
            .environment(\.covers, scene.covers)
            .frame(width: 360, height: 1180)
    }

    private func content(_ scene: ConsoleScene, _ game: ConsoleGame) throws -> ConsolePanelContent {
        let current = try #require(scene.center.game(game.id))
        let system = try #require(scene.center.console(of: current))
        var content = ConsolePanelContent(game: current, console: system, states: scene.center.states(for: current),
                                          bios: scene.center.bios(for: current), playing: nil)
        content.signedIn = scene.center.extras.username != nil
        content.progress = scene.center.extras.progress(for: current)
        return content
    }

    @Test("Achievements: after one sign-in the panel shows the site's unlocked and total for the game")
    func countsAfterSignIn() async throws {
        let scene = try ConsoleScene("extras-counts")
        defer { scene.remove() }
        let game = try await scene.addGame(console: "snes", name: "Cartouche Homebrew", databaseName: "Cartouche Homebrew (World)")
        #expect(try content(scene, game).achievements == "Not signed in")
        let secrets = await Self.signIn(scene)
        #expect(secrets.all == ["player42": "Q1w2E3r4T5y6U7i8"])
        #expect(try content(scene, game).achievements == "Not known yet")
        await scene.center.extras.refresh(game)
        #expect(try content(scene, game).achievements == "12 of 64")
        let compat = try fixtureCompat(scene.work, defaults: scene.scratch)
        for dark in [false, true] {
            let texts = try await renderedTexts(try panel(scene, game.id, compat: compat), size: CGSize(width: 360, height: 1180),
                                                named: "p14-panel-achievements", dark: dark, settle: 0.8)
            #expect(seen(texts, "12 of 64"), "\(texts)")
            #expect(seen(texts, "Play Together") && seen(texts, "Host") && seen(texts, "Join"), "\(texts)")
        }
    }

    @Test("Hardcore: Continue From and Resume are off, and the game starts with no state")
    func hardcoreTurnsOffStates() async throws {
        let scene = try ConsoleScene("extras-hardcore")
        defer { scene.remove() }
        let runner = scene.useFakeRunner(picture: try ConsolePanelTests.screen("AUTO"))
        let game = try await scene.addGame(console: "snes", name: "Cartouche Homebrew", databaseName: "Cartouche Homebrew (World)")
        try scene.writeState(game, slot: nil, picture: try ConsolePanelTests.screen("AUTO"), age: 60)
        try scene.writeState(game, slot: 3, picture: try ConsolePanelTests.screen("SLOT 3"), age: 600)
        #expect(try content(scene, game).playLabel == "Resume")

        await scene.center.setSetup(game.id) { $0.hardcore = true }
        let hardcore = try content(scene, game)
        #expect(!hardcore.statesAllowed)
        #expect(hardcore.playLabel == "Play")
        // Clicking Slot 3 anyway, or Play: no state is loaded
        await scene.center.play(game.id, slot: 3, resume: true, reduceMotion: true)
        let request = try #require(await runner.requests.last)
        #expect(request.hardcore && request.slot == nil && !request.resume)
        await scene.center.quit()

        let compat = try fixtureCompat(scene.work, defaults: scene.scratch)
        for dark in [false, true] {
            let texts = try await renderedTexts(try panel(scene, game.id, compat: compat), size: CGSize(width: 360, height: 1180),
                                                named: "p14-panel-hardcore", dark: dark, settle: 0.8)
            #expect(seen(texts, "Hardcore turns off Continue From"), "\(texts)")
        }
    }

    @Test("Play Together: Host starts netplay with the nickname; Join lists a friend's game from the lobby and joins it")
    func hostAndJoin() async throws {
        let scene = try ConsoleScene("extras-netplay")
        defer { scene.remove() }
        let runner = scene.useFakeRunner(picture: try ConsolePanelTests.screen("AUTO"))
        let game = try await scene.addGame(console: "snes", name: "Cartouche Homebrew", databaseName: "Cartouche Homebrew (World)")
        _ = await Self.signIn(scene)

        await scene.center.host(game.id, reduceMotion: true)
        let hosted = try #require(await runner.requests.last)
        #expect(hosted.netplay == .host(port: 55435, announce: true))
        #expect(hosted.netplayNickname == "player42")
        #expect(scene.center.session.netplay == .host(port: 55435, announce: true))
        await scene.center.quit()

        // The lobby lists the friend's game, by its file name, and one this library lacks
        let lobby = NetplayLobby(base: URL(string: "http://lobby.test/")!) { _ in
            (Data("""
            [{"fields": {"username": "friend", "game_name": "Cartouche Homebrew", "game_crc": "00000000", "core_name": "Snes9x",
              "core_version": "1.63", "ip": "203.0.113.9", "port": 55435, "mitm_ip": "198.51.100.20", "mitm_port": 55436,
              "mitm_session": "abcdef", "host_method": 3, "has_password": false}},
             {"fields": {"username": "other", "game_name": "Some Game", "core_name": "Genesis Plus GX", "ip": "203.0.113.10", "port": 55435}}]
            """.utf8), 200)
        }
        let rooms = await scene.center.netplayRooms(lobby: lobby, local: { [] })
        #expect(rooms.entries.map(\.gameName) == ["Cartouche Homebrew"])
        #expect(rooms.others == 1 && !rooms.localNetwork)
        let entry = try #require(rooms.entries.first)
        await scene.center.join(entry, reduceMotion: true)
        let joined = try #require(await runner.requests.last)
        #expect(joined.netplay == .join(NetplayTarget(address: "198.51.100.20", port: 55436, session: "abcdef")))
        #expect(joined.content == game.fileURL)
        await scene.center.quit()
    }

    @Test("Translate the screen without a service says what is missing and stays off")
    func translationNotConfigured() async throws {
        let scene = try ConsoleScene("extras-translate")
        defer { scene.remove() }
        let game = try await scene.addGame(console: "snes", name: "Cartouche Homebrew", databaseName: "Cartouche Homebrew (World)")
        #expect(ConsoleOptionsSections.needsService == "Needs a translation service, set in Settings")
        scene.center.extras.setTranslate(true, for: game)
        #expect(!scene.center.extras.translates(game))
        let current = try #require(scene.center.game(game.id))
        for dark in [false, true] {
            let sheet = Form { ConsoleOptionsSections(game: current, center: scene.center) }.formStyle(.grouped)
                .frame(width: 480, height: 360)
            let texts = try await renderedTexts(sheet, size: CGSize(width: 480, height: 360), named: "p14-more-options", dark: dark)
            #expect(seen(texts, "Needs a translation service, set in Settings"), "\(texts)")
            #expect(seen(texts, "Coach mode") && seen(texts, "Experimental"), "\(texts)")
        }
        // A run asks RetroArch for no AI service
        var request = PlayRequest(core: URL(fileURLWithPath: "/core"), content: game.fileURL)
        scene.center.extras.apply(to: &request, game: game)
        #expect(request.translation == nil)
    }

    @Test("Settings > Consoles shows the RetroAchievements account, iCloud Drive and the translation service")
    func settingsPane() async throws {
        let scene = try ConsoleScene("extras-settings")
        defer { scene.remove() }
        for dark in [false, true] {
            let texts = try await renderedTexts(ConsolesSettingsView(model: scene.settings, extras: scene.center.extras),
                                                size: CGSize(width: 640, height: 760), named: "p14-settings-signed-out", dark: dark, settle: 0.8)
            #expect(seen(texts, "Sign In") && seen(texts, "Not signed in"), "\(texts)")
            #expect(seen(texts, "Save states to iCloud Drive") && seen(texts, "Not set"), "\(texts)")
        }
        _ = await Self.signIn(scene)
        scene.center.extras.setTranslationService("http://192.168.1.5:4404/")
        for dark in [false, true] {
            let texts = try await renderedTexts(ConsolesSettingsView(model: scene.settings, extras: scene.center.extras),
                                                size: CGSize(width: 640, height: 760), named: "p14-settings-signed-in", dark: dark, settle: 0.8)
            #expect(seen(texts, "Signed in as player42") && seen(texts, "Sign Out"), "\(texts)")
            #expect(seen(texts, "192.168.1.5"), "\(texts)")
        }
    }

    @Test("Coach mode is off by default; on, the game's relay refuses input in Hardcore and reads values")
    func coachRelay() async throws {
        let scene = try ConsoleScene("extras-coach")
        defer { scene.remove() }
        _ = scene.useFakeRunner(picture: try ConsolePanelTests.screen("AUTO"))
        let game = try await scene.addGame(console: "snes", name: "Cartouche Homebrew", databaseName: "Cartouche Homebrew (World)")
        #expect(!scene.center.extras.coaches(game))
        await scene.center.play(game.id, reduceMotion: true)
        #expect(scene.center.coach == nil)
        await scene.center.quit()

        scene.center.extras.setCoach(true, for: game)
        await scene.center.setSetup(game.id) { $0.hardcore = true }
        await scene.center.play(game.id, reduceMotion: true)
        try await Task.sleep(for: .milliseconds(200))
        let relay = try #require(scene.center.coach)
        let pressed = await relay.call("coach_press", ["player": 1, "control": "a", "frames": 3])
        #expect(pressed["isError"] == .bool(true))
        #expect(pressed["content"]?.array?.first?["text"]?.string?.contains("Hardcore mode") == true)
        await scene.center.quit()
        #expect(scene.center.coach == nil)
    }
}
