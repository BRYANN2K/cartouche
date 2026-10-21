import Foundation
import Testing
import InstallerKit
@testable import NotProtonApp

@Suite("Advanced Windows options")
struct AdvancedGameOptionsTests {
    @Test func gating() {
        let cx = GameSetupTests.release
        let hq = GameSetupTests.wine("wine-stable-11.0_1")
        let ours = GameSetupTests.wine("wine-crossover-26.3.0-1")
        let availability = BackendAvailability(crossOverWine: [ours.id], dxmtNVExtensionRunners: [cx.id])
        for backend in GraphicsBackend.allCases {
            let options = AdvancedSupport.options(runner: cx, backend: backend, translation: .rosetta, availability: availability, macOSMajor: 15)
            #expect(options.contains(.msync) && options.contains(.highResolution) && options.contains(.advertiseAVX))
            #expect(options.contains(.spatial) == (backend == .dxmt))
            #expect(options.contains(.dlss) == (backend == .dxmt))
            #expect(options.contains(.metalHUD) == (backend == .dxmt || backend == .d3dmetal))
            let winehq = AdvancedSupport.options(runner: hq, backend: backend, translation: .rosetta, availability: availability)
            #expect(!winehq.contains(.msync) && !winehq.contains(.spatial) && !winehq.contains(.advertiseAVX))
        }
        let fex = AdvancedSupport.options(runner: cx, backend: .dxmt, translation: .fex, availability: availability)
        #expect(!fex.contains(.advertiseAVX) && !fex.contains(.dlss) && !fex.contains(.spatial))
        #expect(!AdvancedSupport.options(runner: cx, backend: .dxmt, translation: .rosetta, availability: .init()).contains(.dlss))
        #expect(AdvancedSupport.options(runner: nil, backend: .dxmt, translation: .rosetta, availability: availability).isEmpty)
    }

    @Test func environmentAndPersistence() throws {
        let options = AdvancedGameOptions(dlss: true, spatial: true, spatialFactor: 1.5, advertiseAVX: true, msync: true, highResolution: true)
        let choice = GameSetupChoice(graphics: .dxmt, metalHUD: true,
                                     environment: ["DXMT_CONFIG": "d3d11.preferredMaxFrameRate=30;"], advanced: options)
        let availability = BackendAvailability(dxmtNVExtensionRunners: [GameSetupTests.release.id])
        let setup = GameSetupResolver.resolve(choice, runners: [GameSetupTests.release], availability: availability).setup
        #expect(setup.environment["WINEMSYNC"] == "1")
        #expect(setup.environment["CARTOUCHE_RETINA"] == "1")
        #expect(setup.environment["DXMT_ENABLE_NVEXT"] == "1")
        #expect(setup.environment["ROSETTA_ADVERTISE_AVX"] == "1")
        #expect(setup.environment["MTL_HUD_ENABLED"] == "1")
        #expect(setup.environment["DXMT_CONFIG"] == "d3d11.preferredMaxFrameRate=30;d3d11.metalSpatialUpscaleFactor=1.5;")
        let work = try scratchDirectory("advanced-settings")
        defer { try? FileManager.default.removeItem(at: work) }
        let store = LibraryStore(folder: work)
        var choices = LibraryChoices(); choices.setups["fixture"] = choice
        try store.save(choices)
        #expect(store.load() == choices)
        let old = try JSONDecoder().decode(GameSetupChoice.self, from: Data(#"{"graphics":"dxmt"}"#.utf8))
        #expect(old.advanced == nil)
        #expect(AdvancedGameOptions() == .init(dlss: false, spatial: false, spatialFactor: 2, advertiseAVX: false, msync: false, highResolution: false))
        try GameSetupApplier.writeEnvironment(setup.environment, appID: 42, setups: work)
        let persisted = try String(contentsOf: work.appending(path: "42.env"), encoding: .utf8)
        #expect(persisted.contains("WINEMSYNC=1\n") && persisted.contains("CARTOUCHE_RETINA=1\n"))
        #expect(!GameSetupResolver.isAllowed(name: "WINESERVER", value: "bad"))
        #expect(!GameSetupResolver.isAllowed(name: "CARTOUCHE_OTHER", value: "1"))
    }

    @Test func incompatibleChoicesDoNotEmitAdvancedVariables() {
        let options = AdvancedGameOptions(dlss: true, spatial: true, advertiseAVX: true, msync: true, highResolution: true)
        let hq = GameSetupTests.wine("wine-stable-11.0_1")
        let choice = GameSetupChoice(graphics: .wined3d, metalHUD: true, advanced: options)
        let resolved = GameSetupResolver.resolve(choice, runners: [hq], availability: .init()).setup
        #expect(resolved.environment.isEmpty)
        let metal = GameSetupResolver.resolve(GameSetupChoice(graphics: .d3dmetal, advanced: options), runners: [GameSetupTests.release],
            availability: .init(d3dMetalRunners: [GameSetupTests.release.id])).setup
        #expect(metal.environment["DXMT_ENABLE_NVEXT"] == nil && metal.environment["DXMT_METALFX_SPATIAL_SWAPCHAIN"] == nil)
        let factor = AdvancedSupport.environment(.init(spatial: true, spatialFactor: 3), supported: [.spatial], existing: [:])
        #expect(factor["DXMT_CONFIG"] == "d3d11.metalSpatialUpscaleFactor=2.0;")
    }

    @Test func extensionFilesRequired() throws {
        let work = try scratchDirectory("advanced-nvext")
        defer { try? FileManager.default.removeItem(at: work) }
        let runner = GameSetupTests.release
        let folder = SupportPaths.clonedRoot(forBuild: runner.id, runners: work).appending(path: "lib/wine/x86_64-windows")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #expect(AdvancedSupport.nvExtensions(runner: runner, runners: work, backends: work) == nil)
        try Data().write(to: folder.appending(path: "nvapi64.dll"))
        #expect(AdvancedSupport.nvExtensions(runner: runner, runners: work, backends: work) == nil)
        try Data().write(to: folder.appending(path: "nvngx.dll"))
        #expect(AdvancedSupport.nvExtensions(runner: runner, runners: work, backends: work) == folder)
    }

    @Test func registryAndSessionFixtures() throws {
        let work = try scratchDirectory("advanced-registry")
        defer { try? FileManager.default.removeItem(at: work) }
        let loader = work.appending(path: "wine")
        let server = work.appending(path: "wineserver")
        let log = work.appending(path: "calls")
        for file in [loader, server] {
            try Data("#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$FIXTURE_LOG\"\n".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        let prefix = work.appending(path: "pfx")
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        let wine = WineRunner(root: work, loader: loader, server: server, dllPath: "")
        let env = ["FIXTURE_LOG": log.path, "WINEPREFIX": prefix.path, "WINEMSYNC": "1", "CARTOUCHE_RETINA": "1"]
        try AdvancedPrefixSettings.apply(wine: wine, prefix: prefix, environment: env)
        var calls = try String(contentsOf: log, encoding: .utf8)
        #expect(calls.hasPrefix("-k\n-w\n"))
        #expect(calls.contains(#"reg add HKCU\Software\Wine\Mac Driver /v RetinaMode /t REG_SZ /d y /f"#))
        try Data().write(to: log)
        try AdvancedPrefixSettings.apply(wine: wine, prefix: prefix, environment: env)
        calls = try String(contentsOf: log, encoding: .utf8)
        #expect(calls.isEmpty)
        #expect(try String(contentsOf: prefix.appending(path: "cartouche-msync"), encoding: .utf8) == "1")
        #expect(AdvancedPrefixSettings.retinaArguments("0").contains("n"))
        let script = GameLauncher.script(exe: work.appending(path: "game.exe"), prefix: prefix, wine: wine, environment: env)
        #expect(script.contains("RetinaMode") && script.contains("cartouche-msync"))
        try Data().write(to: log)
        let launch = work.appending(path: "launch")
        try Data(script.utf8).write(to: launch)
        let launched = try Shell.run("/bin/sh", [launch.path], environment: ["FIXTURE_LOG": log.path, "PATH": "/usr/bin:/bin"])
        #expect(launched.succeeded)
        let launchCalls = try String(contentsOf: log, encoding: .utf8)
        #expect(!launchCalls.contains("-k"))

    }
}
