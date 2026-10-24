import Foundation
import Testing

@testable import NotProtonApp

// Runners built in memory and fixture folders in a scratch directory. No CrossOver,
// Steam or ~/Library folder is read.
@Suite("Game setup")
struct GameSetupTests {

    static func crossOver(_ id: String, fexAvailable: Bool = true) -> Runner {
        let build = SupportedRunners.build(id: id)!
        return Runner(
            id: build.id, kind: .crossOver, version: build.bundleVersion, displayVersion: build.displayVersion,
            flavors: Runner.flavors(of: build, fexAvailable: fexAvailable), state: .ready, build: build,
            source: nil, isInstalled: true)
    }

    // A free runner as the registry lists it once pinned, so it is offered
    static func wine(_ id: String) -> Runner {
        Runner(id: id, kind: .wineBuild, version: id, displayVersion: id, flavors: [.rosetta], state: .ready,
               build: SupportedRunners.all[0], source: nil, isInstalled: true)
    }

    static let release = crossOver("26.3.0.39832")
    static let fexBuild = crossOver("27.0.0.41073-fex")

    func scratchDefaults() -> UserDefaults {
        let name = "cartouche-setup-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("Global defaults are saved, read back, and cleared")
    func defaultsRoundTrip() {
        let defaults = scratchDefaults()
        #expect(SetupDefaults.load(defaults) == SetupDefaults())
        let set = SetupDefaults(runnerID: "26.3.0.39832", graphics: .dxmt, translation: .rosetta)
        set.save(defaults)
        #expect(SetupDefaults.load(defaults) == set)
        SetupDefaults().save(defaults)
        #expect(SetupDefaults.load(defaults) == SetupDefaults())
    }

    @Test("A game's setup is written to library.json and read back; older files without the new fields still load")
    func storeRoundTrip() throws {
        let work = try scratchDirectory("setup-store")
        defer { try? FileManager.default.removeItem(at: work) }
        let store = LibraryStore(folder: work)
        var choices = LibraryChoices()
        choices.setups["steam:1245620"] = GameSetupChoice(
            runnerID: "26.3.0.39832", graphics: .dxmt, translation: .rosetta, metalHUD: true,
            version: .windows, environment: ["DXMT_LOG_LEVEL": "info"])
        try store.save(choices)
        #expect(store.load() == choices)

        try Data(#"{"favorites":[],"hidden":[],"covers":{},"setups":{"steam:730":{"graphics":"dxvk"}}}"#.utf8)
            .write(to: store.file)
        let old = store.load()
        #expect(old.setups["steam:730"] == GameSetupChoice(graphics: .dxvk))
        #expect(old.setups["steam:730"]?.version == nil && old.setups["steam:730"]?.environment == nil)
    }

    @Test("With no choice of its own a game takes the global defaults, and its own choice wins over them")
    func defaultsApply() {
        let availability = BackendAvailability(d3dMetalRunners: [Self.release.id])
        let defaults = SetupDefaults(graphics: .dxvk)
        let plain = GameSetupResolver.resolve(GameSetupChoice(), defaults: defaults, runners: [Self.release], availability: availability)
        #expect(plain.setup.runner?.id == Self.release.id)
        #expect(plain.setup.backend == .dxvk)
        #expect(plain.problems.isEmpty)

        let own = GameSetupResolver.resolve(GameSetupChoice(graphics: .d3dmetal), defaults: defaults,
                                            runners: [Self.release], availability: availability)
        #expect(own.setup.backend == .d3dmetal)

        let none = GameSetupResolver.resolve(GameSetupChoice(), runners: [Self.release], availability: availability)
        #expect(none.setup.backend == .d3dmetal, "the first valid backend when nothing is chosen")
    }

    @Test("A runner without D3DMetal is not offered it, and a stored D3DMetal choice falls back with a problem")
    func noD3DMetal() {
        let without = BackendAvailability()
        #expect(BackendSupport.backends(for: Self.release, translation: .rosetta, availability: without) == [.dxmt, .dxvk, .wined3d])
        let with = BackendAvailability(d3dMetalRunners: [Self.release.id])
        #expect(BackendSupport.backends(for: Self.release, translation: .rosetta, availability: with) == [.d3dmetal, .dxmt, .dxvk, .wined3d])

        let resolved = GameSetupResolver.resolve(GameSetupChoice(graphics: .d3dmetal), runners: [Self.release], availability: without)
        #expect(resolved.setup.backend == .dxmt)
        #expect(resolved.problems == [.backendUnavailable(.d3dmetal)])
    }

    @Test("D3DMetal is never paired with FEX, even on a CrossOver that has it")
    func noD3DMetalOnFEX() {
        let availability = BackendAvailability(d3dMetalRunners: [Self.fexBuild.id])
        #expect(BackendSupport.translations(for: Self.fexBuild) == [.rosetta, .fex])
        #expect(!BackendSupport.backends(for: Self.fexBuild, translation: .fex, availability: availability).contains(.d3dmetal))
        #expect(BackendSupport.backends(for: Self.fexBuild, translation: .rosetta, availability: availability).first == .d3dmetal)

        let resolved = GameSetupResolver.resolve(GameSetupChoice(graphics: .d3dmetal, translation: .fex),
                                                 runners: [Self.fexBuild], availability: availability)
        #expect(resolved.setup.translation == .fex)
        #expect(resolved.setup.backend == .dxmt)
        #expect(resolved.problems == [.backendUnavailable(.d3dmetal)])
    }

    @Test("FEX is not offered on macOS 15, and a stored FEX choice falls back to Rosetta")
    func noFEXOnSequoia() {
        let sequoia = Self.crossOver("27.0.0.41073-fex", fexAvailable: false)
        #expect(BackendSupport.translations(for: sequoia) == [.rosetta])
        let resolved = GameSetupResolver.resolve(GameSetupChoice(translation: .fex), runners: [sequoia],
                                                 availability: BackendAvailability())
        #expect(resolved.setup.translation == .rosetta)
        #expect(resolved.problems == [.translationUnavailable(.fex)])
    }

    @Test("A Wine build gets wined3d, DXVK once downloaded, DXMT only on a Wine built from CrossOver's sources")
    func wineBuilds() {
        let winehq = Self.wine("wine-stable-11.0_1")
        let ours = Self.wine("wine-crossover-26.3.0-1")
        let nothing = BackendAvailability(crossOverWine: [ours.id])
        #expect(BackendSupport.backends(for: winehq, translation: .rosetta, availability: nothing) == [.wined3d])
        let both = BackendAvailability(installed: [.dxmt, .dxvk], crossOverWine: [ours.id])
        #expect(BackendSupport.backends(for: winehq, translation: .rosetta, availability: both) == [.dxvk, .wined3d])
        #expect(BackendSupport.backends(for: ours, translation: .rosetta, availability: both) == [.dxmt, .dxvk, .wined3d])
    }

    @Test("Game Porting Toolkit offers D3DMetal only")
    func toolkit() {
        let gptk = Runner(id: "gptk-3.0", kind: .portingToolkit, version: "3.0", displayVersion: "3.0", flavors: [.rosetta],
                          state: .ready, build: nil, source: nil, isInstalled: true)
        #expect(BackendSupport.backends(for: gptk, translation: .rosetta,
                                        availability: BackendAvailability(d3dMetalRunners: [gptk.id])) == [.d3dmetal])
        #expect(BackendSupport.backends(for: gptk, translation: .rosetta, availability: BackendAvailability()).isEmpty)
    }

    @Test("A runner that is gone is replaced by the first offered one, and the game says so")
    func runnerGone() {
        let resolved = GameSetupResolver.resolve(GameSetupChoice(runnerID: "27.0.0.40921"), runners: [Self.release],
                                                 availability: BackendAvailability())
        #expect(resolved.setup.runner?.id == Self.release.id)
        #expect(resolved.problems == [.runnerUnavailable("27.0.0.40921")])
        let empty = GameSetupResolver.resolve(GameSetupChoice(), runners: [], availability: BackendAvailability())
        #expect(empty.setup.runner == nil && empty.setup.backend == nil)
    }

    @Test("Only variables the run script forwards are kept; the Metal HUD adds its own")
    func environment() {
        let choice = GameSetupChoice(metalHUD: true, environment: [
            "DXMT_LOG_LEVEL": "info", "DXVK_HUD": "fps", "CX_GRAPHICS_BACKEND": "dxvk", "PATH": "/tmp",
            "MTL_X": "a\nb", "dxvk_hud": "1",
        ])
        let resolved = GameSetupResolver.resolve(choice, runners: [Self.release], availability: BackendAvailability())
        #expect(resolved.setup.environment == ["DXMT_LOG_LEVEL": "info", "DXVK_HUD": "fps", "MTL_HUD_ENABLED": "1"])
        #expect(Set(resolved.problems) == [.variableRefused("CX_GRAPHICS_BACKEND"), .variableRefused("PATH"),
                                           .variableRefused("MTL_X"), .variableRefused("dxvk_hud")])
    }

    @Test("A game with a macOS build runs the Mac version unless the Windows version is chosen")
    func version() {
        let runners = [Self.release]
        #expect(GameSetupResolver.resolve(GameSetupChoice(), runners: runners, availability: .init(), hasMacBuild: true).setup.version == .mac)
        #expect(GameSetupResolver.resolve(GameSetupChoice(version: .windows), runners: runners, availability: .init(),
                                          hasMacBuild: true).setup.version == .windows)
        #expect(GameSetupResolver.resolve(GameSetupChoice(version: .mac), runners: runners, availability: .init()).setup.version == .windows)
    }

    @Test("Availability reads D3DMetal from a CrossOver clone's apple_gptk and DXMT from the backends folder")
    func availabilityFromDisk() throws {
        let work = try scratchDirectory("setup-availability")
        defer { try? FileManager.default.removeItem(at: work) }
        let runners = work.appending(path: "runners")
        let backends = work.appending(path: "backends")
        let fm = FileManager.default
        try fm.createDirectory(
            at: SupportPaths.clonedRoot(forBuild: Self.release.id, runners: runners)
                .appending(path: "lib64/apple_gptk/external/D3DMetal.framework"),
            withIntermediateDirectories: true)
        try fm.createDirectory(at: SupportPaths.clonedRoot(forBuild: Self.fexBuild.id, runners: runners), withIntermediateDirectories: true)
        let receipt = BackendInstaller.Receipt(backend: .dxmt, version: "0.80", archiveSHA256: String(repeating: "a", count: 64), files: [:])
        try fm.createDirectory(at: BackendInstaller.folder(for: .dxmt, in: backends), withIntermediateDirectories: true)
        try JSONEncoder().encode(receipt).write(to: BackendInstaller.folder(for: .dxmt, in: backends).appending(path: BackendInstaller.receiptName))

        let registry = RunnerRegistry(runners: [Self.release, Self.fexBuild])
        let availability = BackendAvailability.current(registry: registry, runners: runners, backends: backends,
                                                       manifest: RunnerManifest(format: 1, revision: 0, builds: []))
        #expect(availability.d3dMetalRunners == [Self.release.id])
        #expect(availability.installed == [.dxmt])
    }

    // A Cartouche Wine build plus a user toolkit on disk, all under the scratch folder.
    static func cartoucheManifest() -> RunnerManifest {
        RunnerManifest(format: 1, revision: 1, builds: [
            .init(id: "wine-crossover-26.3.0-1", kind: "wineBuild", origin: .cartouche, name: "Cartouche Wine",
                  version: "26.3.0", displayVersion: "26.3",
                  url: URL(string: "https://github.com/BRYANN2K/cartouche-wine/releases/download/wine-crossover-26.3.0-1/wine-crossover-26.3.0-1-x86_64.tar.xz")!,
                  size: 0, sha256: RunnerManifest.pendingSHA256,
                  root: "wine-crossover-26.3.0-1", loader: "bin/wine", flavors: ["rosetta"]),
            .init(id: "wine-stable-11.0_1", kind: "wineBuild", origin: .winehq, name: "Wine",
                  version: "11.0_1", displayVersion: "11.0",
                  url: URL(string: "https://github.com/Gcenx/x/releases/download/11.0_1/w.tar.xz")!,
                  size: 1, sha256: String(repeating: "ab", count: 32),
                  root: "w", loader: "bin/wine", flavors: ["rosetta"]),
        ])
    }

    // A ready toolkit copy: gptk-<v>/ with its receipt and lib/external/libd3dshared.dylib.
    static func toolkit(in runners: URL, version: String = "4.0b3") throws -> Runner {
        let fm = FileManager.default
        let folder = PortingToolkitSource.folder(version: version, runners: runners)
        try fm.createDirectory(at: folder.appending(path: "lib/external"), withIntermediateDirectories: true)
        try Data("shared".utf8).write(to: folder.appending(path: "lib/external/libd3dshared.dylib"))
        let pe = folder.appending(path: "lib/wine/x86_64-windows")
        try fm.createDirectory(at: pe, withIntermediateDirectories: true)
        for name in ["d3d11", "d3d12", "dxgi"] { try Data("MZ fixture".utf8).write(to: pe.appending(path: "\(name).dll")) }
        let receipt = PortingToolkitSource.Receipt(version: version, origin: "/Volumes/GPTK", files: [:])
        try JSONEncoder().encode(receipt).write(to: folder.appending(path: PortingToolkitSource.receiptName))
        return Runner(id: PortingToolkitSource.runnerID(version: version), kind: .portingToolkit, version: version,
                      displayVersion: version, flavors: [.rosetta], state: .ready, build: nil, source: nil, isInstalled: true)
    }

    @Test("Cartouche Wine counts for DXMT, and D3DMetal comes from the toolkit or its own apple_gptk")
    func cartoucheAvailability() throws {
        let work = try scratchDirectory("setup-cartouche")
        defer { try? FileManager.default.removeItem(at: work) }
        let runners = work.appending(path: "runners")
        let ours = Self.wine("wine-crossover-26.3.0-1")
        let winehq = Self.wine("wine-stable-11.0_1")
        let manifest = Self.cartoucheManifest()

        // No toolkit: CrossOver-capable, but no D3DMetal yet.
        var availability = BackendAvailability.current(registry: RunnerRegistry(runners: [ours, winehq]),
                                                       runners: runners, backends: work.appending(path: "b"),
                                                       manifest: manifest)
        #expect(availability.crossOverWine == [ours.id])
        #expect(availability.d3dMetalRunners.isEmpty)
        #expect(!availability.hasGamePortingToolkit)
        #expect(BackendSupport.missing(.d3dmetal, for: ours, translation: .rosetta, availability: availability)
                == String(localized: "Needs Game Porting Toolkit"))
        #expect(BackendSupport.missing(.d3dmetal, for: winehq, translation: .rosetta, availability: availability)
                == String(localized: "Needs Cartouche Wine and Game Porting Toolkit"))
        #expect(BackendSupport.missing(.dxmt, for: winehq, translation: .rosetta, availability: availability)
                == String(localized: "Needs Cartouche Wine"))

        // The toolkit present: the WineHQ build still cannot load D3DMetal, ours can.
        let toolkit = try Self.toolkit(in: runners)
        availability = BackendAvailability.current(registry: RunnerRegistry(runners: [ours, winehq, toolkit]),
                                                   runners: runners, backends: work.appending(path: "b"),
                                                   manifest: manifest)
        #expect(availability.hasGamePortingToolkit)
        #expect(availability.d3dMetalRunners == Set([ours.id, toolkit.id]))
        #expect(BackendSupport.backends(for: ours, translation: .rosetta, availability: availability).contains(.d3dmetal))
        #expect(BackendSupport.missing(.d3dmetal, for: winehq, translation: .rosetta, availability: availability)
                == String(localized: "Needs Cartouche Wine"))

        // Its own apple_gptk counts even without the user's toolkit.
        let own = WineRunnerInstaller.dir(for: ours.id, runners: runners)
            .appending(path: "lib64/apple_gptk/external/D3DMetal.framework")
        try FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
        try FileManager.default.removeItem(at: PortingToolkitSource.folder(version: "4.0b3", runners: runners))
        availability = BackendAvailability.current(registry: RunnerRegistry(runners: [ours, winehq]),
                                                   runners: runners, backends: work.appending(path: "b"),
                                                   manifest: manifest)
        #expect(availability.d3dMetalRunners == [ours.id])
        #expect(!availability.hasGamePortingToolkit)
    }

    @Test("Without the toolkit our Wine defaults to DXMT and the D3DMetal suggestion leads to the toolkit; with it D3DMetal stays first")
    func d3dMetalOnlyWhenLoadable() {
        let ours = Self.wine("wine-crossover-26.3.0-1")
        var availability = BackendAvailability(installed: [.dxmt], crossOverWine: [ours.id])
        let without = BackendSupport.backends(for: ours, translation: .rosetta, availability: availability)
        #expect(without == [.dxmt, .wined3d])
        #expect(GameSetupResolver.resolve(GameSetupChoice(runnerID: ours.id), runners: [ours],
                                          availability: availability, offered: [ours]).setup.backend == .dxmt)
        // A record still asking for D3DMetal resolves to the best available, flagged
        let asked = GameSetupResolver.resolve(GameSetupChoice(runnerID: ours.id, graphics: .d3dmetal), runners: [ours],
                                              availability: availability, offered: [ours])
        #expect(asked.setup.backend == .dxmt)
        #expect(asked.problems.contains(.backendUnavailable(.d3dmetal)))
        #expect(BackendSupport.needsToolkit(for: ours, translation: .rosetta, availability: availability))
        #expect(GamePanelContent.suggestionAction(.d3dmetal, current: .dxmt, offered: without, needsToolkit: true)
                == .getD3DMetal)
        // A WineHQ build can't load D3DMetal even with the toolkit: no suggestion at all
        let winehq = Self.wine("wine-stable-11.0_1")
        #expect(!BackendSupport.needsToolkit(for: winehq, translation: .rosetta, availability: availability))
        #expect(GamePanelContent.suggestionAction(.d3dmetal, current: .wined3d, offered: [.wined3d], needsToolkit: false)
                == nil)

        availability.d3dMetalRunners = [ours.id]
        let with = BackendSupport.backends(for: ours, translation: .rosetta, availability: availability)
        #expect(with.first == .d3dmetal)
        #expect(!BackendSupport.needsToolkit(for: ours, translation: .rosetta, availability: availability))
        #expect(GamePanelContent.suggestionAction(.d3dmetal, current: .dxmt, offered: with, needsToolkit: false)
                == .use(.d3dmetal))
        #expect(GamePanelContent.suggestionAction(.d3dmetal, current: .d3dmetal, offered: with, needsToolkit: false) == nil)
    }
}
