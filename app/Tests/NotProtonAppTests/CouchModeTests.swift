import CoreGraphics
import Foundation
import Testing

@testable import NotProtonApp

@Suite("Couch mode")
@MainActor
struct CouchModeTests {

    static func press(_ buttons: Set<PadButton>) -> PadState { PadState(pressed: buttons) }

    @Test("A press acts once; a held direction repeats after a pause; the left stick counts as the D-pad")
    func input() {
        var input = CouchInput(initialDelay: 0.4, repeatInterval: 0.1)
        #expect(input.commands(Self.press([.south]), at: 0) == [.accept])
        #expect(input.commands(Self.press([.south]), at: 0.5).isEmpty)
        #expect(input.commands(.idle, at: 0.6).isEmpty)
        #expect(input.commands(Self.press([.right]), at: 1.0) == [.move(.right)])
        #expect(input.commands(Self.press([.right]), at: 1.2).isEmpty)
        #expect(input.commands(Self.press([.right]), at: 1.41) == [.move(.right)])
        #expect(input.commands(Self.press([.right]), at: 1.52) == [.move(.right)])
        #expect(input.commands(PadState(pressed: [], leftStick: CGPoint(x: 0, y: -0.9)), at: 2) == [.move(.down)])
        #expect(input.commands(Self.press([.leftShoulder, .east]), at: 3) == [.back, .previousList])
    }

    @MainActor
    struct Scene {
        let fixture: SteamFixture
        let scratch = ScratchDefaults()
        let model: LibraryModel
        let couch: CouchNavigator
        var played: [String] { _played.value }
        private let _played = Box()

        final class Box { var value: [String] = [] }

        init(_ label: String) async throws {
            fixture = try SteamFixture(label)
            try fixture.writeExport()
            model = libraryModel(fixture, defaults: scratch)
            await model.load()
            couch = CouchNavigator(defaults: scratch.defaults)
            couch.library = model
            couch.gridWidth = 1000
            let box = _played
            couch.play = { box.value.append($0.id) }
        }
    }

    @Test("From launch to Play with the controller only: pick a game, open it, play it")
    func toPlay() async throws {
        let scene = try await Scene("couch")
        defer { scene.fixture.remove() }
        let couch = scene.couch, model = scene.model
        #expect(!couch.isOn && !couch.ringsGame)
        couch.isOn = true
        let games = CouchNavigator.games(model)
        #expect(model.selectedGameID == games.first?.id, "the ring has a game to sit on at once")
        #expect(couch.ringsGame)
        #expect(couch.columns(.portrait) == 5)

        couch.tick(Self.press([.right]), at: 0)
        #expect(model.selectedGameID == games[1].id)
        couch.tick(.idle, at: 0.1)
        couch.tick(Self.press([.down]), at: 0.2)
        #expect(model.selectedGameID == games[6].id)
        couch.tick(.idle, at: 0.3)
        couch.tick(Self.press([.up]), at: 0.4)
        couch.tick(.idle, at: 0.5)
        #expect(model.selectedGameID == games[1].id)

        model.showPanel = false
        couch.tick(Self.press([.south]), at: 0.6)
        #expect(couch.focus == .play && couch.ringsPlay && !couch.ringsGame)
        #expect(model.showPanel)
        couch.tick(.idle, at: 0.7)
        couch.tick(Self.press([.south]), at: 0.8)
        #expect(scene.played == [games[1].id])

        couch.tick(.idle, at: 0.9)
        couch.tick(Self.press([.east]), at: 1.0)
        #expect(couch.focus == .grid && couch.ringsGame)
    }

    @Test("The shoulder buttons change the sidebar list and put the ring on its first game")
    func lists() async throws {
        let scene = try await Scene("couch-lists")
        defer { scene.fixture.remove() }
        scene.couch.isOn = true
        #expect(scene.model.selection == .all)
        scene.couch.perform(.nextList)
        #expect(scene.model.selection == .source(.steam))
        #expect(scene.model.selectedGameID == CouchNavigator.games(scene.model).first?.id)
        scene.couch.perform(.previousList)
        #expect(scene.model.selection == .all)
        scene.couch.perform(.previousList)
        #expect(scene.model.selection == .all)
    }

    @Test("Edges stop the ring; nothing happens while couch mode is off or no controller is there")
    func edges() async throws {
        let scene = try await Scene("couch-edges")
        defer { scene.fixture.remove() }
        let couch = scene.couch, model = scene.model
        let before = model.selectedGameID
        couch.tick(Self.press([.right]), at: 0)
        #expect(model.selectedGameID == before)
        couch.isOn = true
        let first = model.selectedGameID
        couch.perform(.move(.left))
        couch.perform(.move(.up))
        #expect(model.selectedGameID == first)
        couch.tick(nil, at: 1)
        #expect(model.selectedGameID == first)
        couch.isOn = false
        #expect(!couch.ringsGame && !couch.ringsPlay)
        #expect(scene.scratch.defaults.bool(forKey: CouchNavigator.key) == false)
    }
}
