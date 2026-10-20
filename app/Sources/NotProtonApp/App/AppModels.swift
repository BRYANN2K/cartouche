import RetroArchKit
import SwiftUI

extension CartoucheApp {

    var actions: GameActionRunner {
        GameActionRunner(
            model: library,
            showInfo: { [library] in library.showPanel = true },
            afterLaunch: { [afterLaunch] in
                switch afterLaunch {
                case .hide: NSApp.hide(nil)
                case .keepOpen: break
                case .quit: NSApp.terminate(nil)
                }
            },
            playConsole: { [consoleCenter] game in Task { await consoleCenter.play(game.id, resume: true) } },
            stores: stores)
    }

    func makeOnboarding() -> OnboardingModel {
        relaunch.center = permissions
        let systemStatus = status
        let step = SteamStep(
            flow: PermissionFlow(center: permissions),
            install: { [systemStatus] in try await OnboardingSteam.install(through: systemStatus) },
            relaunch: { [relaunch] route in Task { await relaunch.relaunch(to: route) } },
            replace: { [systemStatus] in try await OnboardingSteam.replaceNotProton(through: systemStatus) },
            usesNotProton: { SteamBundle.usesNotProton() })
        let model = OnboardingModel(
            runners: RunnerOffer(
                build: { RunnerOffer.recommended(RunnerManifest.current()) },
                isInstalled: { WineRunnerInstaller.isInstalled($0) },
                install: { [runners, library] build in
                    await runners.download(build.id)
                    guard WineRunnerInstaller.isInstalled(build.id) else {
                        let detail = await runners.message
                        throw StepFailure(
                            step: WineRunnerInstaller.step,
                            detail: detail ?? String(localized: "The download did not install."))
                    }
                    await Self.syncRunnerList(runners: runners, into: library)
                }),
            consoles: .live(paths: consoles.paths), steamStep: step, folders: gameFolders,
            privacy: compat.choices, library: library)
        model.play = { [actions] game in actions.perform(.play, on: game) }
        return model
    }

    // Runners are read through the registry, off the main thread — free builds and the Game Porting Toolkit included, so game setups can offer them
    func loadRunners() async {
        await runners.refresh()
        await syncRunnerList()
        let (tools, platforms, mappings) = await Task.detached {
            (RunnerRegistry.backendTools(),
             SteamAppInfo.platforms(), (SteamCompatChoice.mappings(), SteamCompatChoice.modified()))
        }.value
        library.backendTools = tools
        library.macBuilds = platforms?.both ?? []
        library.adoptSteamChoices(mappings.0, written: mappings.1)
    }

    func syncRunnerList() async {
        await Self.syncRunnerList(runners: runners, into: library)
    }

    static func syncRunnerList(runners: RunnersModel, into library: LibraryModel) async {
        let registry = runners.registry
        let manifest = runners.manifest
        library.runners = registry.runners
        library.backendAvailability = await Task.detached {
            BackendAvailability.current(registry: registry, manifest: manifest)
        }.value
    }
}
