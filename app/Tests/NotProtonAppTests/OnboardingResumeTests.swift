import Foundation
import RetroArchKit
import SwiftUI
import Testing

@testable import NotProtonApp

// Tasks 2.3 and 2.4: the Ready step, and onboarding reopening where it stopped.
// "Quitting" drops the model and builds a new one on the same saved state, as a
// new launch does.
@Suite("Onboarding ready and resume")
@MainActor
struct OnboardingResumeTests {

    @Test("Ready with Steam connected and a free runner: the most recently played installed game, with Play")
    func readyWithSteam() async throws {
        let scene = try OnboardingScene("ready")
        defer { scene.remove() }
        try scene.fixture.writeExport()
        try scene.fixture.addArt([1_245_620])
        await scene.library.load()
        let model = try scene.model()
        var played: [String] = []
        model.play = { played.append($0.id) }
        await model.prepare()
        model.next()
        await model.downloadRunner()
        #expect(model.runnerPhase == .installed)
        #expect(scene.library.steam.account?.accountName == "player42")
        if model.step == .welcome { model.next() }
        while model.step != .ready { model.skip() }

        let game = try #require(model.readyGame)
        // Elden Ring was played yesterday; Counter-Strike 2 a week ago; Apex Legends is not installed
        #expect(game.name == "Elden Ring")
        #expect(game.installed)
        #expect(model.readySummary == "Your library has 8 Steam games.")
        // The runner and the Steam library report on the task list
        #expect(model.readyTasks.map(\.id).contains("runner"))
        #expect(model.readyTasks.map(\.id).contains("steam-library"))
        await scene.render(model, named: "onboarding-ready")

        model.playReadyGame()
        #expect(played == ["steam:1245620"])
        #expect(!model.isPresented)
        #expect(scene.store.load()?.finished == true)
    }

    @Test("Ready with nothing installed says the library is ready, without a game")
    func readyEmpty() async throws {
        let scene = try OnboardingScene("ready-empty", steam: false)
        defer { scene.remove() }
        await scene.library.load()
        let model = try scene.model()
        await model.prepare()
        if model.step == .welcome { model.next() }
        while model.step != .ready { model.skip() }
        #expect(model.readyGame == nil)
        #expect(model.readySummary == "Your library is ready for the games you add.")
    }

    @Test("Quit at each step: the next launch reopens on that step with the choices kept", arguments: OnboardingStep.allCases)
    func quitAtEachStep(_ step: OnboardingStep) async throws {
        let scene = try OnboardingScene("quit-\(step.rawValue)")
        defer { scene.remove() }
        let first = try scene.model()
        first.presentIfDue()
        await first.prepare()
        if step > .welcome { first.next() }
        if step > .stores {
            first.skip()
            first.toggle(try #require(ConsoleCatalog.console("snes")))
        }
        while first.step < step { first.skip() }
        #expect(first.step == step)

        let next = try scene.model()
        next.presentIfDue()

        #expect(next.isPresented)
        #expect(next.step == step)
        #expect(next.resumed == (step != .welcome))
        #expect(next.picked == first.picked)
        if step == .permissions { await scene.render(next, named: "onboarding-resumed-permissions") }
    }

    @Test("Two consoles picked, quit at Controller: reopens there, consoles kept, nothing downloaded again")
    func quitMidway() async throws {
        let scene = try OnboardingScene("quit-midway")
        defer { scene.remove() }
        scene.findings.folders = []
        let buildbot = StubBuildbot.Site("quit-midway")
        for core in ["snes9x", "swanstation"] { try await buildbot.serveCore(core, work: scene.fixture.root) }
        try await buildbot.serveInfo(["snes9x", "swanstation"], work: scene.fixture.root)
        scene.consoles = .live(paths: scene.retroarch, source: buildbot.source, session: StubBuildbot.session)

        let first = try scene.model()
        first.presentIfDue()
        await first.prepare()
        first.next(); first.skip(); first.skip()
        first.toggle(try #require(ConsoleCatalog.console("snes")))
        first.toggle(try #require(ConsoleCatalog.console("ps1")))
        await first.addConsoles()
        #expect(first.step == .controller)
        let downloaded = buildbot.requests.count

        let next = try scene.model()
        next.presentIfDue()
        await next.prepare()
        #expect(next.step == .controller)
        #expect(next.resumed)
        #expect(next.picked == ["snes", "ps1"])

        next.back()
        #expect(next.step == .consoles)
        #expect(next.consolesToAdd.isEmpty)
        await next.addConsoles()
        #expect(next.step == .controller)
        #expect(buildbot.requests.count == downloaded, "nothing was downloaded again")
        let cores = CoreManager(paths: scene.retroarch)
        #expect(await cores.check("snes9x") == .verified)
        #expect(await cores.check("swanstation") == .verified)
    }

    @Test("Start Over goes back to Welcome and forgets the choices, not what was downloaded")
    func startOver() async throws {
        let scene = try OnboardingScene("start-over")
        defer { scene.remove() }
        scene.findings.folders = []
        let first = try scene.model()
        await first.prepare()
        first.next(); first.skip(); first.skip()
        first.toggle(try #require(ConsoleCatalog.console("snes")))
        await first.addConsoles()
        let next = try scene.model()
        next.presentIfDue()
        #expect(next.resumed)

        next.startOver()

        #expect(next.step == .welcome)
        #expect(!next.resumed)
        #expect(scene.store.load()?.addedConsoles == ["snes"])
        #expect(scene.store.load()?.consolesChosen == false)
    }

    @Test("After a relaunch for App Management, onboarding reopens on Stores")
    func relaunchRoute() async throws {
        let scene = try OnboardingScene("relaunch")
        defer { scene.remove() }
        let service = RelaunchService(defaults: scene.scratch.defaults, relauncher: NoRelaunch())
        service.save(.onboarding(step: ScreenRoute.storesStep))

        let model = try scene.model()
        let route = try #require(service.restore())
        model.reopen(on: route)

        #expect(model.isPresented)
        #expect(model.step == .stores)
        #expect(!model.resumed)
    }

    @Test("A v1 relaunch route lands on the step that owns the row now")
    func legacyRoute() async throws {
        let scene = try OnboardingScene("legacy-route")
        defer { scene.remove() }
        let service = RelaunchService(defaults: scene.scratch.defaults, relauncher: NoRelaunch())
        service.save(.onboarding(step: ScreenRoute.pcGamesStep))

        let model = try scene.model()
        let route = try #require(service.restore())
        model.reopen(on: route)

        #expect(model.step == .stores)
    }

    @Test("Interrupted setup tasks restart after relaunch and clear their persisted requests")
    func interruptedSetup() async throws {
        let scene = try OnboardingScene("interrupted-setup")
        defer { scene.remove() }
        var state = OnboardingState()
        state.step = .controller
        state.runnerRequested = true
        state.coreRequests = ["snes"]
        state.addedConsoles = ["snes"]
        scene.store.save(state)
        let model = try scene.model()
        model.restoreSetupTasks()
        #expect(model.setup.runner.started)
        #expect(model.setup.cores["snes"]?.started == true)
        while model.setup.anythingWorking { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.setup.runner.done)
        #expect(scene.store.load()?.runnerRequested == false)
        #expect(scene.store.load()?.coreRequests == [])
        #expect(model.step == .controller)
    }

    @Test("A finished v1 state migrates: onboarding v2 never shows")
    func v1FinishedMigrates() async throws {
        let scene = try OnboardingScene("v1-finished")
        defer { scene.remove() }
        // v1 wrote no version field, a five-step name, and finished = true
        let v1 = """
            {"step": "ready", "consoles": ["snes"], "consolesChosen": true,
             "addedConsoles": ["snes"], "folders": {"/tmp/roms": true}, "finished": true}
            """
        scene.scratch.defaults.set(Data(v1.utf8), forKey: OnboardingStore.key)

        let model = try scene.model()
        model.presentIfDue()

        #expect(!model.isDue)
        #expect(!model.isPresented)
    }

    @Test("A v1 run left mid-way starts v2 at Welcome, keeping what still applies")
    func v1MidRunMigrates() async throws {
        let scene = try OnboardingScene("v1-midrun")
        defer { scene.remove() }
        let v1 = """
            {"step": "consoles", "consoles": ["snes"], "consolesChosen": true,
             "addedConsoles": ["snes"], "folders": {"/tmp/roms": true}, "finished": false}
            """
        scene.scratch.defaults.set(Data(v1.utf8), forKey: OnboardingStore.key)

        let model = try scene.model()
        model.presentIfDue()

        #expect(model.isDue)
        #expect(model.step == .welcome)
        #expect(model.resumed == false)
        #expect(scene.store.load()?.version == 2)
        // Consoles added earlier stay added; folder choices carry over
        #expect(scene.store.load()?.addedConsoles == ["snes"])
        #expect(scene.store.load()?.folders == ["/tmp/roms": true])
    }
}

@MainActor
struct NoRelaunch: Relauncher {
    func relaunch() -> Bool { true }
}
