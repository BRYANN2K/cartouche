import Foundation
import RetroArchKit
import SwiftUI
import Testing

@testable import NotProtonApp

// Task 2.2: seven steps, all skippable except Welcome and Ready. The package
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
        let next = try scene.model()
        next.presentIfDue()
        #expect(!next.isPresented)
    }

    @Test("Welcome and Ready are not skippable; every step between them is")
    func skipRules() async throws {
        let scene = try OnboardingScene("skip-rules")
        defer { scene.remove() }
        let model = try scene.model()
        model.presentIfDue()
        await model.prepare()

        // skip() on Welcome does not move
        model.skip()
        #expect(model.step == .welcome)

        var seen: [OnboardingStep] = [model.step]
        model.next()  // Set Up
        seen.append(model.step)
        while model.step != .ready {
            #expect(model.step.skippable)
            model.skip()
            seen.append(model.step)
        }
        #expect(seen == OnboardingStep.allCases)
        #expect(OnboardingStep.allCases.count == 7)
        #expect(!model.step.skippable)

        // skip() on Ready does not move
        model.skip()
        #expect(model.step == .ready)
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
        }
    }

    @Test("Continue on Windows games starts the runner download in the background")
    func continueStartsRunner() async throws {
        let scene = try OnboardingScene("bg-runner")
        defer { scene.remove() }
        let model = try scene.model()
        model.presentIfDue()
        await model.prepare()

        model.next()
        #expect(model.step == .windowsGames)
        #expect(model.runner?.id == OnboardingScene.wine.id)
        #expect(!model.setup.runner.started)

        model.next()  // Continue
        #expect(model.step == .stores)
        #expect(model.setup.runner.started)
        #expect(model.setup.activity?.title == "Wine CrossOver 26.3")
        while model.setup.runner.working {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(model.setup.runner.done)
        #expect(model.runnerPhase == .installed)
        #expect(scene.counts.runnerInstalls == [OnboardingScene.wine.id])
        // The same work reports through the activity slot
        #expect(model.setup.activity == nil)
    }

    @Test("An untoggled runner stays put; Skip never starts the download")
    func skipNeverStartsRunner() async throws {
        let scene = try OnboardingScene("skip-runner")
        defer { scene.remove() }
        let model = try scene.model()
        await model.prepare()
        model.next()
        model.skip()
        #expect(model.step == .stores)
        #expect(!model.setup.runner.started)
        #expect(scene.counts.runnerInstalls.isEmpty)
    }

    @Test("App Management is asked only in Stores, and only when Steam is set up")
    func appManagementOnlyInStores() async throws {
        let scene = try OnboardingScene("app-management")
        defer { scene.remove() }
        let model = try scene.model()
        await model.prepare()

        // Through every step, Set Up untouched: no explanation, no write into Steam
        model.next()
        model.skip()
        while model.step != .ready {
            #expect(model.steamStep.flow.asking == nil, "\(model.step)")
            model.skip()
        }
        #expect(model.steamStep.flow.asking == nil)
        #expect(scene.counts.steamInstalls == 0)
        while model.step != .stores { model.back() }

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

        // A permission that needs a relaunch is refused in onboarding
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
        for core in cores { try await buildbot.serveCore(core, work: scene.fixture.root) }
        try await buildbot.serveInfo(cores, work: scene.fixture.root)
        scene.consoles = .live(paths: scene.retroarch, source: buildbot.source, session: StubBuildbot.session)
        let model = try scene.model()
        await model.prepare()
        model.next()
        model.skip()
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
        #expect(model.step == .controller)
        let fetched = buildbot.requests.filter { $0.hasPrefix("/cores/") }
        #expect(fetched == ["/cores/snes9x_libretro.dylib.zip", "/cores/swanstation_libretro.dylib.zip"])
        let installed = try FileManager.default.contentsOfDirectory(atPath: scene.retroarch.cores.path(percentEncoded: false))
        #expect(installed.sorted() == ["snes9x_libretro.dylib", "swanstation_libretro.dylib"])
        #expect(await scene.consoleSetup().added() == ["snes", "ps1"])
        #expect(scene.store.load()?.addedConsoles == ["snes", "ps1"])
    }

    @Test("Consoles: Continue starts the core downloads without waiting")
    func continueStartsCores() async throws {
        let scene = try OnboardingScene("bg-cores")
        defer { scene.remove() }
        scene.findings.folders = []
        let model = try scene.model()
        await model.prepare()
        model.next()
        model.skip()
        model.skip()
        #expect(model.step == .consoles)

        model.toggle(try #require(ConsoleCatalog.console("snes")))
        model.toggle(try #require(ConsoleCatalog.console("ps1")))
        model.next()  // Continue
        #expect(model.step == .controller)
        while model.setup.cores.values.contains(where: \.working) {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(scene.counts.consoleAdds.sorted() == ["ps1", "snes"])
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

    @Test("Consoles: the ROM folder is watched once Continue is pressed")
    func romFolderWatched() async throws {
        let scene = try OnboardingScene("rom-folder")
        defer { scene.remove() }
        let model = try scene.model()
        await model.prepare()
        model.next()
        model.skip()
        model.skip()
        #expect(model.step == .consoles)
        #expect(model.folderRows.map(\.id).contains(SupportPaths.home.appending(path: "Games/ROMs").plainPath))

        model.addFolder(URL(filePath: "/tmp/more-roms"))
        model.next()

        #expect(model.step == .controller)
        #expect(scene.folders.paths.count == 2)
    }

    @Test("Only the manifest-pinned Wine CrossOver is recommended, never WineHQ")
    func crossOverDefault() throws {
        let manifest = try RunnerManifest.bundled()
        #expect(RunnerOffer.recommended(manifest)?.id == "wine-crossover-26.3.0-1")
        let wineHQOnly = RunnerManifest(format: manifest.format, revision: manifest.revision,
                                      builds: manifest.builds.filter { $0.origin == .winehq })
        #expect(RunnerOffer.recommended(wineHQOnly) == nil)
    }

    @Test("Windows games: the free runner is preselected; D3DMetal follows the toolkit")
    func windowsGamesStep() async throws {
        let scene = try OnboardingScene("windows-games")
        defer { scene.remove() }
        let model = try scene.model()
        await model.prepare()
        model.next()
        #expect(model.step == .windowsGames)
        #expect(model.runner?.id == "wine-crossover-26.3.0-1")
        #expect(model.runner?.origin == .cartouche)
        #expect(model.wantsRunner)
        #expect(model.runnerPhase == .notInstalled)
        // No toolkit on this Mac: the drop zone copy is shown
        #expect(!model.toolkitReady)
        await scene.render(model, named: "onboarding-windows-games")
        // Continue's task strip names the pinned runner immediately, before work yields.
        model.next()
        #expect(model.setup.activity?.title == "Wine CrossOver 26.3")
        await scene.render(model, named: "onboarding-wine-background", modes: [.classic])
        model.back()

        // A dropped .dmg imports through the setup task
        model.importToolkitImage(URL(filePath: "/tmp/game-porting-toolkit.dmg"))
        while model.setup.toolkit.working {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.setup.toolkit.done)
        #expect(model.toolkitReady)
        await model.downloadRunner()
        #expect(model.runnerPhase == .installed)
    }

    @Test("Without Steam the Stores step says how to get it and asks nothing")
    func storesWithoutSteam() async throws {
        let scene = try OnboardingScene("no-steam", steam: false)
        defer { scene.remove() }
        let model = try scene.model()
        await model.prepare()
        model.next()
        model.skip()
        #expect(model.step == .stores)
        #expect(model.findings?.steam == nil)
        await scene.render(model, named: "onboarding-stores-no-steam", modes: [.classic])
        #expect(scene.counts.steamInstalls == 0)
    }

    @Test("Permissions: only what the earlier choices made necessary")
    func permissionListFollowsChoices() async throws {
        let scene = try OnboardingScene("permissions")
        defer { scene.remove() }
        let model = try scene.model()
        await model.prepare()

        model.controllerKeys = true
        model.watchDownloads = true
        // Controller mapping opted in, Downloads watching on
        #expect(model.neededPermissions == [.accessibility, .downloads])

        model.controllerKeys = false
        #expect(model.neededPermissions == [.downloads])
        model.watchDownloads = false
        #expect(model.neededPermissions == [])
        model.wantsRunner = false
        #expect(model.neededPermissions == [])

        // An external games disk adds Removable Volumes
        model.chooseGamesFolder(URL(filePath: "/Volumes/Games/Windows"))
        #expect(model.neededPermissions == [.removableVolumes])
    }

    @Test("Permissions: asking goes through the explanation flow")
    func permissionAsk() async throws {
        let scene = try OnboardingScene("perm-ask")
        defer { scene.remove() }
        scene.tcc.decide(.accessibility, .granted)
        let model = try scene.model()
        await model.prepare()

        model.ask(.accessibility)
        let flow = try #require(model.permissionFlow)
        #expect(flow.asking?.permission == .accessibility)
        await flow.confirm()
        #expect(model.permissionState(.accessibility) == .allowed)
    }

    @Test("Permissions and privacy: choices apply and survive a relaunch")
    func permissionsStep() async throws {
        let scene = try OnboardingScene("perm-step")
        defer { scene.remove() }
        let model = try scene.model()
        await model.prepare()
        while model.step != .permissions {
            if model.step == .welcome { model.next() } else { model.skip() }
        }
        #expect(model.step == .permissions)

        model.privacy.fetchMacReports = false
        model.chooseGamesFolder(URL(filePath: "/tmp/games"))
        await scene.render(model, named: "onboarding-permissions", modes: [.classic])

        let next = try scene.model()
        #expect(PrivacyChoices(defaults: scene.scratch.defaults).fetchMacReports == false)
        #expect(next.step == .permissions)
        #expect(next.state.gamesFolder == "/tmp/games")
    }
}
