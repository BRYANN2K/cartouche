import Foundation
import RetroArchKit
import Testing

@testable import NotProtonApp

// The P15 controls tools over the fixture backend: every call lands on the
// same GameControls the Controls sheet writes, and Steam games stay refused.
@MainActor
private func controlsService(
    _ level: AgentLevel = .full
) -> (service: AgentService, backend: AgentFixture) {
    let root = URL(filePath: NSTemporaryDirectory())
        .appending(path: "cartouche-controls-tests").appending(path: UUID().uuidString)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let backend = AgentFixture(home: root)
    return (AgentService(backend: backend, level: level,
                         providers: [AgentControls()], home: root), backend)
}

private func installerGame(_ slug: String = "hades", name: String = "Hades") -> Game {
    Game(id: "installer:\(slug)", source: .installer, name: name, installed: true)
}

@MainActor
private func snesGame() -> Game {
    ConsoleCenter.libraryGame(ConsoleGame(
        console: "snes", name: "Super Mario World", databaseName: nil,
        file: URL(filePath: "/tmp/smw.sfc"), identifiedBy: .fileName))
}

private func payload(_ reply: JSONValue) -> JSONValue? { reply["structuredContent"] }

private func errorText(_ reply: JSONValue) -> String? {
    reply["content"]?.array?.first?["text"]?.string
}

@Suite("Agent controls tools")
struct AgentControlsTests {

    @Test("list_controllers names each pad with family and battery")
    @MainActor
    func controllers() async {
        let (service, backend) = controlsService()
        backend.controllerList = [
            ControllerInfo(id: "1", name: "DualSense Wireless Controller",
                           shortName: "DualSense", family: .playStation,
                           battery: 0.8, charging: true),
            ControllerInfo(id: "2", name: "Xbox Wireless Controller",
                           shortName: "Xbox", family: .xbox, battery: nil),
        ]
        let reply = await service.call("list_controllers", [:], client: "test")
        #expect(reply["isError"] == .bool(false))
        let pads = payload(reply)?["controllers"]?.array
        #expect(pads?.count == 2)
        #expect(pads?[0]["name"] == .string("DualSense Wireless Controller"))
        #expect(pads?[0]["family"] == .string("playStation"))
        #expect(pads?[0]["charging"] == .bool(true))
        #expect(pads?[1]["battery"] == .null)
    }

    @Test("get_controls says who handles the layout and the current mapping")
    @MainActor
    func getControls() async {
        let (service, backend) = controlsService()
        let wine = installerGame()
        let steam = Game(id: "steam:1245620", source: .steam, name: "Elden Ring",
                         steamAppID: 1245620, installed: true)
        backend.gameList = [wine, steam, snesGame()]
        var controls = GameControls()
        controls.layout = .preset(.swapAB)
        backend.controlsByGame[wine.id] = controls

        let cartouche = await service.call("get_controls",
            ["game": .string(wine.id)], client: "test")
        #expect(payload(cartouche)?["handler"] == .string("cartouche"))
        #expect(payload(cartouche)?["layout"]?["preset"] == .string("swap_ab"))

        let steamReply = await service.call("get_controls",
            ["game": .string(steam.id)], client: "test")
        #expect(payload(steamReply)?["handler"] == .string("steam_input"))
        #expect(payload(steamReply)?["note"] != nil)

        let console = await service.call("get_controls",
            ["game": .string(snesGame().id)], client: "test")
        #expect(payload(console)?["handler"] == .string("retroarch"))
    }

    @Test("set_controls writes a button swap for a Wine game")
    @MainActor
    func setControls() async {
        let (service, backend) = controlsService()
        let game = installerGame()
        backend.gameList = [game]
        let reply = await service.call("set_controls",
            ["game": .string(game.id),
             "buttons": .object(["south": .string("east"), "east": .string("south")]),
             "swap_sticks": .bool(true)], client: "test")
        #expect(reply["isError"] == .bool(false))
        #expect(backend.gameControls(game.id).layout.target(of: .south) == .east)
        #expect(backend.gameControls(game.id).layout.swapSticks)
        #expect(backend.calls.contains("controls:\(game.id)"))
    }

    @Test("set_controls picks a preset by name")
    @MainActor
    func setPreset() async {
        let (service, backend) = controlsService()
        let game = installerGame()
        backend.gameList = [game]
        let reply = await service.call("set_controls",
            ["game": .string(game.id), "preset": .string("southpaw")], client: "test")
        #expect(reply["isError"] == .bool(false))
        #expect(backend.gameControls(game.id).layout == .preset(.southpaw))
    }

    @Test("set_controls on a Steam game is refused and points at Steam Input")
    @MainActor
    func steamRefused() async {
        let (service, backend) = controlsService()
        let game = Game(id: "steam:1245620", source: .steam, name: "Elden Ring",
                        steamAppID: 1245620, installed: true)
        backend.gameList = [game]
        let reply = await service.call("set_controls",
            ["game": .string(game.id), "preset": .string("swap_ab")], client: "test")
        #expect(reply["isError"] == .bool(true))
        #expect(errorText(reply)?.contains("Steam Input") == true)
        #expect(backend.controlsByGame.isEmpty)
    }

    @Test("set_keyboard_mouse sets the Mac driver options, refuses console games")
    @MainActor
    func keyboardMouse() async {
        let (service, backend) = controlsService()
        let game = installerGame()
        backend.gameList = [game, snesGame()]
        let reply = await service.call("set_keyboard_mouse",
            ["game": .string(game.id), "command_as_control": .bool(true),
             "keep_mouse_inside": .bool(false)], client: "test")
        #expect(reply["isError"] == .bool(false))
        #expect(backend.gameControls(game.id).keyboard.commandAsControl)
        #expect(backend.gameControls(game.id).keyboard.keepMouseInside == false)
        #expect(backend.gameControls(game.id).keyboardSet)

        let console = await service.call("set_keyboard_mouse",
            ["game": .string(snesGame().id), "command_as_control": .bool(true)], client: "test")
        #expect(console["isError"] == .bool(true))
        #expect(errorText(console)?.contains("console game") == true)
    }

    @Test("Play with a controller asks the app for Accessibility, never the agent")
    @MainActor
    func keyboardGame() async {
        let (service, backend) = controlsService()
        let game = installerGame()
        backend.gameList = [game]

        let denied = await service.call("set_controller_for_keyboard_game",
            ["game": .string(game.id), "on": .bool(true)], client: "test")
        #expect(denied["isError"] == .bool(true))
        #expect(errorText(denied)?.contains("Accessibility") == true)
        #expect(backend.controlsByGame.isEmpty)

        backend.accessibility = true
        let reply = await service.call("set_controller_for_keyboard_game",
            ["game": .string(game.id), "on": .bool(true)], client: "test")
        #expect(reply["isError"] == .bool(false))
        #expect(backend.gameControls(game.id).playWithController)
    }

    @Test("a controls change is undone from the action log")
    @MainActor
    func undo() async throws {
        let (service, backend) = controlsService()
        let game = installerGame()
        backend.gameList = [game]
        var before = GameControls()
        before.layout = .preset(.swapAB)
        backend.controlsByGame[game.id] = before

        let reply = await service.call("set_controls",
            ["game": .string(game.id), "preset": .string("standard")], client: "test")
        #expect(reply["isError"] == .bool(false))
        #expect(backend.gameControls(game.id).layout.isStandard)

        let action = try #require(service.actions.last { $0.canUndo })
        try await service.undo(action.id)
        #expect(backend.gameControls(game.id).layout == .preset(.swapAB))
        #expect(service.actions.contains { $0.undone })
    }

    @Test("read-only level refuses set_controls")
    @MainActor
    func readOnly() async {
        let (service, backend) = controlsService(.readOnly)
        let game = installerGame()
        backend.gameList = [game]
        let reply = await service.call("set_controls",
            ["game": .string(game.id), "preset": .string("swap_ab")], client: "test")
        #expect(reply["isError"] == .bool(true))
        #expect(service.actions.contains {
            $0.outcome == .refused("needs standard access; the level is readOnly") })
    }
}
