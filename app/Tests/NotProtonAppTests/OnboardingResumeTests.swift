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
        while model.step != .ready { model.skip() }

        let game = try #require(model.readyGame)
        // Elden Ring was played yesterday; Counter-Strike 2 a week ago; Apex Legends is not installed
        #expect(game.name == "Elden Ring")
        #expect(game.installed)
        #expect(model.readySummary == "Your library has 8 Steam games.")
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
        if step > .pcGames {
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
        if step == .folders { await scene.render(next, named: "onboarding-resumed-folders") }
    }

    @Test("Two consoles picked, quit at Folders and privacy: reopens there, consoles kept, nothing downloaded again")
    func quitMidway() async throws {
        let scene = try OnboardingScene("quit-midway")
        defer { scene.remove() }
        scene.findings.folders = []
        let buildbot = StubBuildbot.Site("quit-midway")
        for core in ["snes9x", "swanstation"] { try buildbot.serveCore(core, work: scene.fixture.root) }
        try buildbot.serveInfo(["snes9x", "swanstation"], work: scene.fixture.root)
        scene.consoles = .live(paths: scene.retroarch, source: buildbot.source, session: StubBuildbot.session)

        let first = try scene.model()
        first.presentIfDue()
        await first.prepare()
        first.next(); first.skip()
        first.toggle(try #require(ConsoleCatalog.console("snes")))
        first.toggle(try #require(ConsoleCatalog.console("ps1")))
        await first.addConsoles()
        #expect(first.step == .folders)
        let downloaded = buildbot.requests.count

        let next = try scene.model()
        next.presentIfDue()
        await next.prepare()
        #expect(next.step == .folders)
        #expect(next.resumed)
        #expect(next.picked == ["snes", "ps1"])

        next.back()
        #expect(next.step == .consoles)
        #expect(next.consolesToAdd.isEmpty)
        await next.addConsoles()
        #expect(next.step == .folders)
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
        first.next(); first.skip()
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

    @Test("After a relaunch for App Management, onboarding reopens on PC games")
    func relaunchRoute() async throws {
        let scene = try OnboardingScene("relaunch")
        defer { scene.remove() }
        let service = RelaunchService(defaults: scene.scratch.defaults, relauncher: NoRelaunch())
        service.save(.onboarding(step: ScreenRoute.pcGamesStep))

        let model = try scene.model()
        let route = try #require(service.restore())
        model.reopen(on: route)

        #expect(model.isPresented)
        #expect(model.step == .pcGames)
        #expect(!model.resumed)
    }
}

@MainActor
struct NoRelaunch: Relauncher {
    func relaunch() -> Bool { true }
}
