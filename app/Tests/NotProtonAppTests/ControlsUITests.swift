import Foundation
import RetroArchKit
import SwiftUI
import Testing

@testable import NotProtonApp

// The Controls screens on a scratch library, with simulated controllers and a
// stand-in for TCC. Nothing posts events, opens Steam or asks macOS for a permission.
@MainActor
struct ControlsScene {
    let fixture: SteamFixture
    let scratch: ScratchDefaults
    let tcc: FakeTCC
    let permissions: PermissionCenter
    let model: LibraryModel
    let compat: CompatibilityModel
    let center: ControlsCenter
    let source = FakeControllerSource()
    let pad = FakePad()
    let poster = RecordingInputPoster()
    let focus = FakeFocus()
    let relaunch: RelaunchService
    let relauncher = FakeRelauncher()
    let files: ControlsFiles
    let opened = Opened()

    final class Opened { var urls: [URL] = [] }

    init(_ label: String, tcc: FakeTCC = FakeTCC(), scratch: ScratchDefaults = ScratchDefaults(),
         fixture: SteamFixture? = nil) async throws {
        self.fixture = try fixture ?? SteamFixture(label)
        if fixture == nil { try self.fixture.writeExport() }
        self.scratch = scratch
        self.tcc = tcc
        permissions = makeCenter(tcc, scratch)
        await permissions.refresh()
        model = libraryModel(self.fixture, defaults: scratch)
        await model.load()
        compat = try await fixtureCompat(self.fixture.root.appending(path: "compat-\(UUID().uuidString)"), defaults: scratch)
        files = ControlsFiles(installs: self.fixture.root.appending(path: "installs"),
                              setups: self.fixture.root.appending(path: "setups"),
                              retroArch: RetroArchPaths(root: self.fixture.root.appending(path: "retroarch")))
        center = ControlsCenter(permissions: permissions, files: files, store: ControlsStore(folder: self.fixture.support),
                                source: source, reader: pad, poster: poster, focus: focus, tap: FakeTap(),
                                defaults: scratch.defaults)
        center.isActive = { true }
        center.backgroundEvents = { _ in }
        let opened = opened
        center.open = { opened.urls.append($0) }
        relaunch = RelaunchService(defaults: scratch.defaults, center: permissions, games: FakeGames(),
                                   relauncher: relauncher, pollInterval: .milliseconds(5))
        center.connect(relaunch: relaunch, library: model)
        center.monitor.start()
        await center.load()
    }

    var actions: GameActionRunner {
        let opened = opened
        return GameActionRunner(model: model, open: { opened.urls.append($0) })
    }

    func panel(_ game: Game) -> some View {
        GamePanel(game: game, model: model, compat: compat, actions: actions)
            .environment(center)
            .environment(\.covers, fixture.covers())
    }

    func sheet(_ game: Game) -> some View {
        center.present(game)
        return ControlsSheet(center: center, session: center.session!)
    }

    // Every file under the scratch folders Controls writes to
    var written: [String] {
        [files.installs, files.setups, files.retroArch.root].flatMap { root in
            (FileManager.default.enumerator(atPath: root.path)?.allObjects as? [String] ?? []).map { "\(root.lastPathComponent)/\($0)" }
        }
    }

    func installed(_ slug: String, name: String) throws -> Game {
        let folder = GameFolder(root: files.installs.appending(path: slug))
        try FileManager.default.createDirectory(at: folder.prefix, withIntermediateDirectories: true)
        let game = Game(id: "installer:\(slug)", source: .installer, name: name, installed: true)
        model.otherGames.append(game)
        return game
    }

    func remove() { fixture.remove() }
}

@Suite("Controls screens", .serialized)
@MainActor
struct ControlsUITests {

    @Test("A DualSense shows in Settings > Controllers and the game panel with its battery, within 2 seconds")
    func dualSense() async throws {
        let scene = try await ControlsScene("controls-dualsense")
        defer { scene.remove() }
        let game = try #require(scene.model.game("steam:1245620"))
        let settings = UIHost(ControllersSettingsView(center: scene.center), size: CGSize(width: 640, height: 420))
        let panel = UIHost(scene.panel(game), size: CGSize(width: 360, height: 1100))
        defer { settings.close(); panel.close() }
        await settings.settle()
        #expect(try !settings.texts().contains { $0.contains("DualSense") })

        let connected = ContinuousClock.now
        scene.source.connect(FakeControllerSource.dualSense)
        await settings.settle(0.1)
        // One reading of each window, as drawn
        let listed = try settings.texts()
        let shown = try panel.texts()
        let took = ContinuousClock.now - connected
        #expect(listed.contains { $0.contains("DualSense Wireless Controller") }, "\(listed)")
        #expect(listed.contains { $0.contains("80%") }, "\(listed)")
        #expect(shown.contains { $0.contains("DualSense") }, "\(shown)")
        #expect(shown.contains { $0.contains("Battery 80%") }, "\(shown)")
        #expect(took < .seconds(2), "shown after \(took)")
        print("evidence: DualSense and 80% drawn in Settings > Controllers and the panel, read back \(took) after connecting")
        _ = try settings.texts(named: "controllers-settings")
        _ = try panel.texts(named: "controls-panel-dualsense")
        for dark in [true] {
            await windowSnapshot(ControllersSettingsView(center: scene.center), named: "controllers-settings",
                                 size: CGSize(width: 640, height: 420), dark: dark)
        }
    }

    @Test("Customize on a Steam game: Steam Input handles it, Open in Steam, and Cartouche changes nothing")
    func steamGame() async throws {
        let scene = try await ControlsScene("controls-steam")
        defer { scene.remove() }
        let game = try #require(scene.model.game("steam:1245620"))
        let host = UIHost(scene.sheet(game), size: CGSize(width: 560, height: 600))
        defer { host.close() }
        #expect(try await host.wait(for: "Steam Input handles this game"))
        #expect(try host.texts().contains("Open in Steam"))
        _ = try host.texts(named: "controls-steam-game")
        scene.center.openInSteam(game)
        #expect(scene.opened.urls == [URL(string: "steam://nav/games/details/1245620")!])
        scene.center.dismiss()
        #expect(scene.written.isEmpty, "\(scene.written)")
        #expect(await scene.center.store.all().isEmpty)
        #expect(scene.tcc.requests.isEmpty)
        await windowSnapshot(scene.sheet(game), named: "controls-steam-game", size: CGSize(width: 560, height: 600), dark: true)
    }

    @Test("Swap Cross and Circle in a Wine game's Controls: saved, and its launcher's mapping written")
    func wineGame() async throws {
        let scene = try await ControlsScene("controls-wine")
        defer { scene.remove() }
        let game = try scene.installed("hades", name: "Hades")
        scene.source.connect(FakeControllerSource.dualSense)
        let host = UIHost(scene.sheet(game), size: CGSize(width: 560, height: 600))
        defer { host.close() }
        #expect(try await host.wait(for: "The game sees an Xbox controller"))
        await scene.center.update(game) {
            $0.layout.set(.south, sends: .east)
            $0.layout.set(.east, sends: .south)
        }
        let mapping = try String(contentsOf: GameFolder(root: scene.files.installs.appending(path: "hades")).controllerMapping, encoding: .utf8)
        #expect(mapping.contains("a:b1,b:b0,"))
        #expect(await ControlsStore(folder: scene.fixture.support).controls(game.id).layout.target(of: .south) == .east)
        await host.settle()
        _ = try host.texts(named: "controls-wine-cross-circle")
    }

    @Test("Swap A/B for a SNES game, picked in the sheet: its RetroArch remap file is written")
    func consoleGame() async throws {
        let scene = try await ControlsScene("controls-snes")
        defer { scene.remove() }
        let rom = ConsoleGame(console: "snes", name: "Super Mario World", databaseName: "Super Mario World (USA)",
                              file: scene.fixture.root.appending(path: "Super Mario World (USA).sfc"), identifiedBy: .checksum)
        let game = ConsoleCenter.libraryGame(rom)
        let host = UIHost(scene.sheet(game), size: CGSize(width: 560, height: 600))
        defer { host.close() }
        #expect(try await host.wait(for: "Swap A/B"))
        #expect(await host.select(segment: "Swap A/B"))
        try await Task.sleep(for: .milliseconds(200))
        let file = RetroArchRemap.file(core: "snes9x", content: rom.contentName, paths: scene.files.retroArch)
        #expect(try String(contentsOf: file, encoding: .utf8) == RetroArchRemap.render(.preset(.swapAB)))
        #expect(scene.center.controls(for: game).layout.preset == .swapAB)
        _ = try host.texts(named: "controls-snes-swap-ab")
        print("evidence: \(file.path)")
    }

    @Test("Play with a controller needs Accessibility: nothing runs for the game until macOS allows it")
    func accessibility() async throws {
        let scene = try await ControlsScene("controls-ax", tcc: FakeTCC([.accessibility: .notGranted]))
        defer { scene.remove() }
        let game = try scene.installed("hades", name: "Hades")
        await scene.center.update(game) { $0.playWithController = true }
        scene.focus.front = game.id
        scene.pad.state = PadState(pressed: [.south])
        scene.center.tick(now: 0)
        #expect(scene.center.keyboardPlayGames.isEmpty)
        #expect(scene.poster.posted.isEmpty)

        // Turned on from the sheet: Cartouche explains first, then macOS asks
        scene.center.present(game)
        let option = try #require(scene.center.session?.play)
        option.set(true)
        #expect(scene.center.session?.play.flow.asking?.permission == .accessibility)
        #expect(scene.tcc.requests.isEmpty)
        scene.tcc.decide(.accessibility, .granted)
        await option.flow.confirm()
        #expect(option.isOn)
        #expect(scene.tcc.requests == [.accessibility])
        scene.center.tick(now: 1)
        #expect(scene.center.keyboardPlayGames.map(\.id) == [game.id])
        #expect(scene.poster.posted == [.key(49, down: true)])

        // Another app in front: the held key goes up, and nothing more is posted
        scene.focus.front = nil
        scene.pad.state = PadState(pressed: [.east])
        scene.center.tick(now: 2)
        #expect(scene.poster.posted == [.key(49, down: true), .key(49, down: false)])
        scene.center.session?.opensOnKeyboard = true
        let sheet = UIHost(ControlsSheet(center: scene.center, session: scene.center.session!), size: CGSize(width: 560, height: 620))
        defer { sheet.close() }
        #expect(try await sheet.wait(for: "Play with a controller"))
        _ = try sheet.texts(named: "controls-keyboard-tab")
    }

    @Test("Remap keys: Input Monitoring is asked from Controls, and after Quit & Reopen Cartouche reopens there with it on")
    func relaunchReopensControls() async throws {
        let tcc = FakeTCC([.inputMonitoring: .undetermined])
        let scratch = ScratchDefaults()
        let first = try await ControlsScene("controls-relaunch", tcc: tcc, scratch: scratch)
        defer { first.remove() }
        let game = try first.installed("hades", name: "Hades")
        first.center.present(game)
        let remap = try #require(first.center.session?.remap)
        remap.set(true)
        #expect(remap.flow.asking?.explanation.relaunch != nil)
        // macOS: Later in its alert, the answer comes after a relaunch
        await remap.flow.confirm()
        #expect(remap.status == "Waiting for a relaunch")
        #expect(first.relaunch.banner?.title == "Relaunch Cartouche to finish")
        let sheet = UIHost(ControlsSheet(center: first.center, session: first.center.session!), size: CGSize(width: 560, height: 600))
        #expect(try await sheet.wait(for: "Waiting for a relaunch"))
        _ = try sheet.texts(named: "controls-relaunch-later")
        sheet.close()

        // The user allows it in System Settings and macOS quits Cartouche; a new copy starts
        tcc.set(.inputMonitoring, .granted)
        let second = try await ControlsScene("controls-relaunch-2", tcc: tcc, scratch: scratch, fixture: first.fixture)
        second.model.otherGames.append(game)
        let route = try #require(second.relaunch.restore())
        #expect(route == .controls(game: game.id, finishing: .inputMonitoring))
        await second.center.reopen(route)
        #expect(second.center.presented?.id == game.id)
        #expect(second.center.session?.remap.isOn == true)
        #expect(second.center.controls(for: game).remapKeys)
        #expect(second.model.selectedGameID == game.id)
        #expect(tcc.requests == [.inputMonitoring], "asked a second time")
        let reopened = UIHost(ControlsSheet(center: second.center, session: second.center.session!), size: CGSize(width: 560, height: 620))
        defer { reopened.close() }
        #expect(try await reopened.wait(for: "Remap keys for this game"))
        #expect(try !reopened.texts(named: "controls-relaunch-reopened").contains { $0.contains("Waiting for a relaunch") })
    }

    @Test("Couch mode from launch to a running game with the controller only, a ring at every step")
    func couchToPlay() async throws {
        let scene = try await ControlsScene("controls-couch")
        defer { scene.remove() }
        scene.source.connect(FakeControllerSource.dualSense)
        scene.center.couch.play = { [actions = scene.actions] game in actions.perform(game.installed ? .play : .install, on: game) }
        scene.center.couch.isOn = true
        let window = LibraryWindow(model: scene.model, compat: scene.compat, steamSetup: SteamSetup(steps: SteamSetup.Steps(), defaults: scene.scratch.defaults),
                                   actions: scene.actions)
            .environment(scene.center)
            .environment(\.covers, scene.fixture.covers())
        let host = UIHost(window, size: CGSize(width: 1280, height: 800))
        defer { host.close() }
        await host.settle(0.6)
        #expect(scene.center.couch.gridWidth > 0)
        var time = 0.0
        func press(_ buttons: Set<PadButton>) async {
            scene.pad.state = PadState(pressed: buttons)
            scene.center.tick(now: time)
            time += 0.1
            scene.pad.state = .idle
            scene.center.tick(now: time)
            time += 0.1
            await host.settle(0.3)
        }
        let games = CouchNavigator.games(scene.model)
        #expect(scene.model.selectedGameID == games[0].id && scene.center.couch.ringsGame)
        _ = try host.texts(named: "couch-1-launch")
        await press([.right])
        await press([.right])
        #expect(scene.model.selectedGameID == games[2].id)
        // On to the next installed game, so Play starts it rather than installing it
        while scene.model.selectedGame?.installed == false { await press([.right]) }
        let game = try #require(scene.model.selectedGame)
        _ = try host.texts(named: "couch-2-picked")
        await press([.south])
        #expect(scene.center.couch.ringsPlay && scene.model.showPanel)
        _ = try host.texts(named: "couch-3-play-focused")
        await press([.south])
        let id = try #require(game.steamAppID)
        #expect(scene.opened.urls.last == URL(string: "steam://rungameid/\(id)"))
        print("evidence: couch mode played \(game.name): \(scene.opened.urls.last!)")
        _ = try host.texts(named: "couch-4-played")
        #expect(scene.tcc.requests.isEmpty)
    }
}
