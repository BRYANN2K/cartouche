import Foundation
import InstallerKit
import Testing
@testable import NotProtonApp

// One profile per game, read and written by the game page, the launch and the in-game menu
@MainActor
@Suite("Shared game profile")
struct GameProfileTests {
    let d3dMetal = BackendAvailability(d3dMetalRunners: [GameSetupTests.release.id])

    func model(_ setups: [String: GameSetupChoice] = [:]) throws -> (LibraryModel, URL) {
        let work = try scratchDirectory("profile")
        let store = LibraryStore(folder: work)
        var choices = LibraryChoices()
        choices.setups = setups
        try store.save(choices)
        return (LibraryModel(store: store, defaults: ScratchDefaults().defaults), work)
    }

    @Test("Defaults are the in-game menu's: temporal at 67 %, HUD hidden top left, Metal HUD hidden")
    func defaults() {
        let s = OverlaySettings()
        #expect(s.upscale == .temporal && s.renderScale == 67 && s.sharpness == 30)
        #expect(s.hud == .hidden && s.corner == .topLeft && s.hideMetalHUD)
        #expect(s.fitted(dlss: false).upscale == .spatial)
    }

    @Test("The old switches migrate as they played")
    func migration() {
        let dlss = GameSetupChoice(advanced: AdvancedGameOptions(dlss: true))
        #expect(GameProfile.migrated(dlss, first: true).upscale == .temporal)
        let spatial = GameSetupChoice(advanced: AdvancedGameOptions(spatial: true, spatialFactor: 1.5))
        #expect(GameProfile.migrated(spatial, first: true).upscale == .spatial)
        #expect(GameProfile.migrated(spatial, first: true).renderScale == 67)
        let msyncOnly = GameSetupChoice(advanced: AdvancedGameOptions(msync: true))
        #expect(GameProfile.migrated(msyncOnly, first: true).upscale == .off)
        // A later write of MSync alone leaves the upscaling the user set since
        var since = OverlaySettings(); since.upscale = .spatial
        #expect(GameProfile.migrated(msyncOnly, onto: since, first: false).upscale == .spatial)
        #expect(GameProfile.migrated(GameSetupChoice(metalHUD: true), first: true).hideMetalHUD == false)
        let cleared = GameProfile.cleared(GameSetupChoice(metalHUD: true, advanced: AdvancedGameOptions(dlss: true, msync: true)))
        #expect(cleared.metalHUD == nil && cleared.advanced == AdvancedGameOptions(msync: true))
        #expect(GameProfile.cleared(GameSetupChoice(advanced: AdvancedGameOptions(dlss: true))).advanced == nil)
        #expect(GameProfile.factor(renderScale: 50) == 2 && GameProfile.factor(renderScale: 100) == 1)
        #expect(GameProfile.renderScale(factor: 2) == 50 && GameProfile.renderScale(factor: .nan) == 67)
    }

    @Test("Opening the library moves old switches into the profile file and clears them from the setup")
    func libraryMigrates() throws {
        let (model, work) = try model([
            "steam:1": GameSetupChoice(graphics: .d3dmetal, metalHUD: true, advanced: AdvancedGameOptions(dlss: true, msync: true)),
            "steam:2": GameSetupChoice(graphics: .dxmt, advanced: AdvancedGameOptions(advertiseAVX: true)),
            "steam:3": GameSetupChoice(graphics: .dxmt),
        ])
        defer { try? FileManager.default.removeItem(at: work) }
        let menu = OverlayProfileStore(folder: work.appending(path: "Overlay"))
        #expect(menu.profile(for: "steam:1")?.upscale == .temporal)
        #expect(menu.profile(for: "steam:1")?.hideMetalHUD == false)
        #expect(menu.profile(for: "steam:2")?.upscale == .off)
        #expect(menu.profile(for: "steam:3") == nil)
        #expect(model.profile(for: "steam:3") == OverlaySettings())
        #expect(model.setup(for: "steam:1").metalHUD == nil)
        #expect(model.setup(for: "steam:1").advanced == AdvancedGameOptions(msync: true))
        #expect(LibraryStore(folder: work).load().setups["steam:2"]?.advanced == AdvancedGameOptions(advertiseAVX: true))
        // A second launch has nothing left to move
        let again = LibraryModel(store: LibraryStore(folder: work), defaults: ScratchDefaults().defaults)
        #expect(again.profile(for: "steam:2").upscale == .off)
    }

    @Test("The page and the in-game menu edit the same file")
    func sharedWithMenu() throws {
        let (model, work) = try model()
        defer { try? FileManager.default.removeItem(at: work) }
        var page = model.profile(for: "steam:7")
        page.upscale = .spatial
        page.renderScale = 58
        page.hud = .full
        model.setProfile(page, for: "steam:7")
        let center = OverlayCenter(game: OverlayGame(id: "steam:7", name: "Hollow Pines", pid: 1, dlss: true), store: model.profiles, soon: [])
        #expect(center.settings.upscale == .spatial && center.settings.renderScale == 58 && center.settings.hud == .full)
        center.set(.hud, HUDLevel.mini.rawValue)
        center.save()
        model.profileSaved("steam:7")
        #expect(model.profile(for: "steam:7").hud == .mini)
        #expect(model.profile(for: "steam:7").renderScale == 58)
    }

    @Test("A write of an old switch, by the agent or a fix, lands in the profile")
    func absorbsLegacyWrites() throws {
        let (model, work) = try model()
        defer { try? FileManager.default.removeItem(at: work) }
        var choice = model.setup(for: "steam:9")
        choice.metalHUD = true
        choice.graphics = .dxmt
        model.setSetup(choice, for: "steam:9")
        #expect(model.setup(for: "steam:9").metalHUD == nil)
        #expect(model.setup(for: "steam:9").graphics == .dxmt)
        #expect(model.profile(for: "steam:9").hideMetalHUD == false)
    }

    @Test("The launch reads the profile: DLSS for temporal, nothing of the menu for a protected game")
    func launchEnvironment() {
        let runners = [GameSetupTests.release]
        let choice = GameSetupChoice(graphics: .d3dmetal, translation: .rosetta)
        func env(_ s: OverlaySettings, protected: Bool = false, dlss: Bool = true) -> [String: String] {
            GameSetupResolver.resolve(choice, runners: runners, availability: d3dMetal,
                                      profile: LaunchProfile(settings: s, protected: protected, dlss: dlss)).setup.environment
        }
        var s = OverlaySettings()
        #expect(env(s)["D3DM_ENABLE_METALFX"] == "1")
        #expect(env(s)["CARTOUCHE_OVERLAY"] == "off" && env(s)["MTL_HUD_ENABLED"] == "0")
        s.upscale = .off
        #expect(env(s)["D3DM_ENABLE_METALFX"] == "0")
        #expect(env(s)["CARTOUCHE_FRAMEGEN_TEMPORAL"] == "off")
        s.hideMetalHUD = false
        #expect(env(s)["MTL_HUD_ENABLED"] == "1")
        #expect(GameSetupResolver.resolve(choice, runners: runners, availability: d3dMetal,
                                          profile: LaunchProfile(settings: s)).setup.metalHUD)
        // Under an anti-cheat the layer's DLSS stays, our variables go; no DLSS in the game, no MetalFX variable
        let locked = env(OverlaySettings(), protected: true)
        #expect(locked["D3DM_ENABLE_METALFX"] == "1" && locked["CARTOUCHE_OVERLAY"] == nil)
        #expect(env(OverlaySettings(), protected: true, dlss: false)["D3DM_ENABLE_METALFX"] == nil)
        // A DXMT game's spatial mode is MetalFX's, at the inverse of the render scale
        let dxmt = GameSetupChoice(graphics: .dxmt, translation: .rosetta)
        s.upscale = .spatial
        s.renderScale = 50
        let spatial = GameSetupResolver.resolve(dxmt, runners: runners, availability: BackendAvailability(),
                                                profile: LaunchProfile(settings: s)).setup.environment
        #expect(spatial["DXMT_METALFX_SPATIAL_SWAPCHAIN"] == "1")
        #expect(spatial["DXMT_CONFIG"]?.contains("d3d11.metalSpatialUpscaleFactor=2.0") == true)
    }

    @Test("The profile loads our library by itself: temporal or HUD on, never for a protected game, never interpolating")
    func libraryFromProfile() throws {
        let runners = [GameSetupTests.release]
        var choice = GameSetupChoice(graphics: .d3dmetal, translation: .rosetta)
        // A variable typed by hand before 0.2.0 no longer decides
        choice.environment = ["CARTOUCHE_FRAMEGEN": "1"]
        func env(_ s: OverlaySettings, protected: Bool = false) -> [String: String] {
            GameSetupResolver.resolve(choice, runners: runners, availability: d3dMetal,
                                      profile: LaunchProfile(settings: s, protected: protected, dlss: true)).setup.environment
        }
        var s = OverlaySettings()
        s.hud = .hidden
        let temporal = env(s)
        #expect(temporal["CARTOUCHE_FRAMEGEN"] == "1" && temporal["D3DM_ENABLE_METALFX"] == "1")
        #expect(temporal["CARTOUCHE_FRAMEGEN_TEMPORAL"] == nil)
        #expect(temporal["CARTOUCHE_FRAMEGEN_INTERPOLATE"] == nil, "the launch sets it, off")
        s.upscale = .off
        let none = env(s)
        #expect(none["CARTOUCHE_FRAMEGEN"] == nil)
        s.upscale = .spatial
        #expect(env(s)["CARTOUCHE_FRAMEGEN"] == nil, "D3DMetal's spatial mode is not our chain")
        s.upscale = .off
        s.hud = .mini
        let hud = env(s)
        #expect(hud["CARTOUCHE_FRAMEGEN"] == "1" && hud["CARTOUCHE_FRAMEGEN_TEMPORAL"] == "off")
        #expect(env(OverlaySettings(), protected: true)["CARTOUCHE_FRAMEGEN"] == nil)
        // The library has nothing to hook outside the Metal backends
        #expect(OverlayLaunch.environment(OverlaySettings(), supported: [], protected: false, existing: [:])["CARTOUCHE_FRAMEGEN"] == nil)

        // Both launch paths carry it: Steam's setup file and an installed game's launcher
        let work = try scratchDirectory("profile-library")
        defer { try? FileManager.default.removeItem(at: work) }
        try GameSetupApplier.writeEnvironment(hud, appID: 1422450, setups: work)
        let file = try String(contentsOf: work.appending(path: "1422450.env"), encoding: .utf8)
        #expect(file.contains("CARTOUCHE_FRAMEGEN=1\n") && !file.contains("INTERPOLATE"))
        try GameSetupApplier.writeEnvironment(none, appID: 1422450, setups: work)
        #expect(!(try String(contentsOf: work.appending(path: "1422450.env"), encoding: .utf8)).contains("CARTOUCHE_FRAMEGEN=1"))
        let wine = WineRunner(root: work, loader: work.appending(path: "wine"), server: work.appending(path: "wineserver"), dllPath: "")
        let script = GameLauncher.script(exe: work.appending(path: "game.exe"), prefix: work.appending(path: "pfx"), wine: wine,
                                         environment: hud)
        #expect(script.contains("export CARTOUCHE_FRAMEGEN=\(GameLauncher.quote("1"))"))
        #expect(script.contains("export CARTOUCHE_FRAMEGEN_INTERPOLATE=0"))
    }

    @Test("A failed legacy-profile copy keeps the old id; a good one moves it")
    func legacyProfileCopy() throws {
        let old = OverlaySettings()
        var lines: [String] = []
        let log: (String) -> Void = { lines.append($0) }

        // Copy works: the profile lands under the library id
        let ok = OverlayProfileStore(folder: try scratchDirectory("profiles-ok"))
        try ok.save(old, for: "hollow-pines")
        var overlay = OverlayGame(id: "steam:1", name: "Hollow Pines", pid: 1)
        CartoucheApp.keepLegacyProfile("hollow-pines", for: &overlay, profiles: ok, log: log)
        #expect(overlay.id == "steam:1")
        #expect(ok.profile(for: "steam:1") == old)
        #expect(lines.isEmpty)

        // Copy fails: the menu keeps reading the old id and the failure is logged
        let dir = try scratchDirectory("profiles-ro")
        let blocked = OverlayProfileStore(folder: dir)
        try blocked.save(old, for: "hollow-pines")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path(percentEncoded: false))
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path(percentEncoded: false)) }
        var stuck = OverlayGame(id: "steam:2", name: "Hollow Pines", pid: 2)
        CartoucheApp.keepLegacyProfile("hollow-pines", for: &stuck, profiles: blocked, log: log)
        #expect(stuck.id == "hollow-pines")
        #expect(lines.count == 1)
    }
}
