import Foundation
import RetroArchKit
import SwiftUI
import Testing

@testable import NotProtonApp

// Task 2.2: five skippable steps, App Management only in PC games. The package
// has no XCUITest target, so these drive the model the onboarding view binds to,
// the way its buttons do, and render each step offscreen into CARTOUCHE_SNAPSHOTS.
@Suite("Onboarding steps")
@MainActor
struct OnboardingFlowTests {

    @Test("Skip Setup on Welcome: the library opens, nothing was downloaded or modified")
    func skipSetup() async throws {
        let scene = try OnboardingScene("skip-setup")
        defer { scene.remove() }
        let model = try scene.model()
        model.presentIfDue()
        #expect(model.isPresented)
        await model.prepare()

        model.skipAll()

        #expect(!model.isPresented)
        #expect(scene.store.load()?.finished == true)
        #expect(scene.untouched)
        // Once over, it does not come back at the next launch
        let next = try scene.model()
        next.presentIfDue()
        #expect(!next.isPresented)
    }

    @Test("Skip on every step: the library opens, nothing was downloaded or modified")
    func skipEveryStep() async throws {
        let scene = try OnboardingScene("skip-all")
        defer { scene.remove() }
        let model = try scene.model()
        model.presentIfDue()
        await model.prepare()
        var seen: [OnboardingStep] = [model.step]

        model.next()  // Set Up
        seen.append(model.step)
        while model.step != .ready {
            #expect(model.canContinue)
            model.skip()
            seen.append(model.step)
        }
        #expect(seen == OnboardingStep.allCases)
        #expect(OnboardingStep.allCases.count <= 5)
        model.finish()  // Open Library

        #expect(!model.isPresented)
        #expect(scene.untouched)
        // Found folders were offered but not kept, since the step was skipped
        #expect(scene.folders.paths.isEmpty)
    }

    @Test("Every choice is in Settings afterwards")
    func choicesInSettings() async throws {
        let scene = try OnboardingScene("settings")
        defer { scene.remove() }
        let model = try scene.model()
        await model.prepare()
        model.skipAll()

        // Consoles and privacy have their own panes; setup, folders and the runner got a section each
        #expect(SettingsTab.allCases.contains(.consoles))
        #expect(SettingsTab.allCases.contains(.privacy))
        model.runAgain()
        #expect(model.isPresented)
        #expect(model.step == .welcome)
        await model.downloadRunner()
        #expect(model.runnerPhase == .installed)
        scene.folders.add(URL(filePath: "/tmp/roms"))
        #expect(scene.folders.paths == ["/tmp/roms"])

        for dark in [false, true] {
            let general = Form { SetupAssistantSection() }.formStyle(.grouped).environment(model)
            snapshot(general.frame(width: 560), named: "settings-general-setup", dark: dark)
            let library = Form { LibraryFoldersSection() }.formStyle(.grouped).environment(scene.folders)
            snapshot(library.frame(width: 560), named: "settings-library-folders", dark: dark)
            let runner = Form { FreeRunnerSection() }.formStyle(.grouped).environment(model)
            snapshot(runner.frame(width: 560), named: "settings-compatibility-runner", dark: dark)
        }
    }

    @Test("App Management is asked only in PC games, and only when Steam is set up")
    func appManagementOnlyInPCGames() async throws {
        let scene = try OnboardingScene("app-management")
        defer { scene.remove() }
        let model = try scene.model()
        await model.prepare()

        // Through every step, Set Up untouched: no explanation, no write into Steam
        model.next()
        while model.step != .ready {
            #expect(model.steamStep.flow.asking == nil, "\(model.step)")
            model.skip()
        }
        #expect(model.steamStep.flow.asking == nil)
        #expect(scene.counts.steamInstalls == 0)
        while model.step != .pcGames { model.back() }

        model.steamStep.setUp()
        #expect(model.steamStep.flow.asking?.permission == .appManagement)
        await model.steamStep.flow.confirm()
        #expect(scene.counts.steamInstalls == 1)
        #expect(model.steamStep.phase == .blocked(.appManagement))
        // Denied, the rest of onboarding goes on
        #expect(model.canContinue)
        model.next()
        #expect(model.step == .consoles)
        // macOS has no prompt for App Management, and nothing else was asked
        #expect(scene.tcc.requests.isEmpty)

        // Any other permission is refused in onboarding
        var outcome: PermissionFlow.Outcome?
        model.steamStep.flow.start(.inputMonitoring, context: .onboarding) { outcome = $0 }
        #expect(outcome == .refused)
    }

    @Test("Consoles: Super Nintendo and PlayStation download only their cores, and the PlayStation BIOS is named")
    func consolesStep() async throws {
        let scene = try OnboardingScene("consoles")
        defer { scene.remove() }
        // No console folder found, so nothing is picked for the user
        scene.findings.folders = []
        let buildbot = StubBuildbot.Site("consoles")
        let cores = ["snes9x", "swanstation", "mgba", "sameboy"]
        for core in cores { try buildbot.serveCore(core, work: scene.fixture.root) }
        try buildbot.serveInfo(cores, work: scene.fixture.root)
        scene.consoles = .live(paths: scene.retroarch, source: buildbot.source, session: StubBuildbot.session)
        let model = try scene.model()
        await model.prepare()
        model.next()
        model.skip()
        #expect(model.step == .consoles)
        #expect(model.consolesToAdd.isEmpty)

        let snes = try #require(ConsoleCatalog.console("snes"))
        let ps1 = try #require(ConsoleCatalog.console("ps1"))
        model.toggle(snes)
        model.toggle(ps1)
        #expect(model.consolesToAdd.map(\.id) == ["snes", "ps1"])
        let bios = try #require(model.biosNotes.first)
        #expect(bios.console.id == "ps1")
        #expect(bios.message == "scph5501.bin is missing")
        for dark in [false, true] {
            await sheetSnapshot(OnboardingView(model: model).environment(\.glassMode, .classic),
                                named: "onboarding-consoles-macos15", dark: dark)
        }
        await scene.render(model, named: "onboarding-consoles", modes: [.liquid])

        await model.addConsoles()

        #expect(model.consoleProblem == nil)
        #expect(model.step == .folders)
        let fetched = buildbot.requests.filter { $0.hasPrefix("/cores/") }
        #expect(fetched == ["/cores/snes9x_libretro.dylib.zip", "/cores/swanstation_libretro.dylib.zip"])
        let installed = try FileManager.default.contentsOfDirectory(atPath: scene.retroarch.cores.path(percentEncoded: false))
        #expect(installed.sorted() == ["snes9x_libretro.dylib", "swanstation_libretro.dylib"])
        #expect(await scene.consoleSetup().added() == ["snes", "ps1"])
        #expect(scene.store.load()?.addedConsoles == ["snes", "ps1"])
    }

    @Test("Consoles with games in a found folder start picked")
    func foundConsolesPicked() async throws {
        let scene = try OnboardingScene("found-consoles")
        defer { scene.remove() }
        let model = try scene.model()
        await model.prepare()
        #expect(model.picked == ["gb", "gba", "ps1"])
        #expect(model.foundGames(try #require(ConsoleCatalog.console("gb"))) == 37)
        // A pick by the user is kept, and found consoles no longer pick themselves
        model.toggle(try #require(ConsoleCatalog.console("gb")))
        let again = try scene.model()
        await again.prepare()
        #expect(again.picked == ["gba", "ps1"])
    }

    @Test("Folders and privacy: Continue keeps the chosen folders, privacy choices apply at once")
    func foldersStep() async throws {
        let scene = try OnboardingScene("folders")
        defer { scene.remove() }
        let model = try scene.model()
        await model.prepare()
        model.next(); model.skip(); model.skip()
        #expect(model.step == .folders)
        #expect(model.folderRows.map(\.id) == [SupportPaths.home.appending(path: "Games/ROMs").plainPath])
        model.addFolder(URL(filePath: "/tmp/more-roms"))
        model.privacy.fetchMacReports = false
        await scene.render(model, named: "onboarding-folders", modes: [.classic])

        model.next()

        #expect(model.step == .ready)
        #expect(scene.folders.paths.count == 2)
        #expect(PrivacyChoices(defaults: scene.scratch.defaults).fetchMacReports == false)
    }

    @Test("PC games: the free runner downloads from its row; the step renders blocked and done")
    func pcGamesStep() async throws {
        let scene = try OnboardingScene("pc-games")
        defer { scene.remove() }
        let model = try scene.model()
        await model.prepare()
        model.next()
        #expect(model.runner?.id == OnboardingScene.wine.id)
        #expect(model.runnerPhase == .notInstalled)
        await scene.render(model, named: "onboarding-pc-games")
        await model.downloadRunner()
        #expect(model.runnerPhase == .installed)
        #expect(scene.counts.runnerInstalls == [OnboardingScene.wine.id])
        model.steamStep.setUp()
        await model.steamStep.flow.confirm()
        await scene.render(model, named: "onboarding-pc-games-blocked", modes: [.classic])
    }

    @Test("Without Steam the PC games step says how to get it and asks nothing")
    func pcGamesWithoutSteam() async throws {
        let scene = try OnboardingScene("no-steam", steam: false)
        defer { scene.remove() }
        let model = try scene.model()
        await model.prepare()
        model.next()
        #expect(model.findings?.steam == nil)
        await scene.render(model, named: "onboarding-pc-games-no-steam", modes: [.classic])
        #expect(scene.counts.steamInstalls == 0)
    }
}
