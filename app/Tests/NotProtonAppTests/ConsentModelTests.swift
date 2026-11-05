import Foundation
import Testing
@testable import NotProtonApp

// Decision of 2026-10-30: under an anti-cheat, Off and the layer's DLSS → MetalFX need no consent;
// Spatial, our chain and the in-game HUD need Cartouche Sharpening, per game, off by default there
@MainActor
@Suite("Anti-cheat consent")
struct ConsentModelTests {
    let d3dMetal = BackendAvailability(d3dMetalRunners: [GameSetupTests.release.id])

    func env(_ s: OverlaySettings, graphics: GraphicsBackend = .d3dmetal, protected: Bool, dlss: Bool) -> [String: String] {
        let choice = GameSetupChoice(graphics: graphics, translation: .rosetta)
        return GameSetupResolver.resolve(choice, runners: [GameSetupTests.release],
                                         availability: graphics == .d3dmetal ? d3dMetal : BackendAvailability(),
                                         profile: LaunchProfile(settings: s, protected: protected, dlss: dlss)).setup.environment
    }

    @Test("What runs: Off and Temporal with DLSS need no consent, Spatial needs it")
    func effectiveModes() {
        let base = UpscaleAccess(dlss: true, sharpening: false)
        #expect(base.effective(.temporal) == .temporal)
        #expect(base.effective(.spatial) == .off)
        #expect(!base.allows(.spatial) && base.allows(.temporal) && base.allows(.off))
        #expect(!base.scales(.temporal), "the layer's DLSS leaves the scale to the game")
        let noDLSS = UpscaleAccess(dlss: false, sharpening: false)
        #expect(UpscaleMode.allCases.allSatisfy { noDLSS.effective($0) == .off })
        let full = UpscaleAccess(dlss: false, sharpening: true)
        #expect(full.effective(.temporal) == .spatial && full.scales(.spatial))
    }

    @Test("Never D3DM_ENABLE_METALFX for a game without DLSS, whatever the profile")
    func neverMetalFXWithoutDLSS() {
        for mode in UpscaleMode.allCases {
            for protected in [false, true] {
                for sharpening in [nil, false, true] as [Bool?] {
                    var s = OverlaySettings()
                    s.upscale = mode
                    s.sharpening = sharpening
                    let e = env(s, protected: protected, dlss: false)
                    #expect(e["D3DM_ENABLE_METALFX"] == nil, "\(mode) protected=\(protected) sharpening=\(String(describing: sharpening))")
                }
            }
        }
        #expect(env(OverlaySettings(), protected: false, dlss: true)["D3DM_ENABLE_METALFX"] == "1")
    }

    @Test("Under an anti-cheat without consent: the layer's DLSS, nothing of ours")
    func protectedWithoutConsent() {
        let e = env(OverlaySettings(), protected: true, dlss: true)
        #expect(e["D3DM_ENABLE_METALFX"] == "1")
        for key in ["CARTOUCHE_FRAMEGEN", "CARTOUCHE_OVERLAY", "CARTOUCHE_OVERLAY_POS", "CARTOUCHE_OVERLAY_CONTROL", "CARTOUCHE_FRAMEGEN_TEMPORAL"] {
            #expect(e[key] == nil, "\(key)")
        }
        var s = OverlaySettings()
        s.upscale = .spatial
        #expect(env(s, graphics: .dxmt, protected: true, dlss: false)["DXMT_METALFX_SPATIAL_SWAPCHAIN"] == nil)
        #expect(env(s, graphics: .dxmt, protected: false, dlss: false)["DXMT_METALFX_SPATIAL_SWAPCHAIN"] == "1")
    }

    @Test("With consent, or on a normal game by default, our library loads")
    func consentLoadsLibrary() {
        var s = OverlaySettings()
        s.sharpening = true
        let consented = env(s, protected: true, dlss: true)
        #expect(consented["CARTOUCHE_FRAMEGEN"] == "1" && consented["CARTOUCHE_OVERLAY"] == "off")
        // A clean game keeps the v0.1.2 environment: the library loads only for temporal or a shown HUD
        #expect(env(OverlaySettings(), protected: false, dlss: false)["CARTOUCHE_FRAMEGEN"] == nil)
        s.hud = .mini
        #expect(env(s, protected: false, dlss: false)["CARTOUCHE_FRAMEGEN"] == "1")
        s.sharpening = false
        let revoked = env(s, protected: false, dlss: true)
        #expect(revoked["CARTOUCHE_FRAMEGEN"] == nil && revoked["D3DM_ENABLE_METALFX"] == "1")
    }

    @Test("The switch: per game, asks under an anti-cheat, stores the default as nil")
    func switchRules() {
        #expect(SharpeningConsent.asks(true, protected: true))
        #expect(!SharpeningConsent.asks(false, protected: true) && !SharpeningConsent.asks(true, protected: false))
        #expect(SharpeningConsent.stored(true, protected: true) == true)
        #expect(SharpeningConsent.stored(false, protected: true) == nil)
        #expect(SharpeningConsent.stored(true, protected: false) == nil)
        #expect(SharpeningConsent.stored(false, protected: false) == false)
        #expect(OverlaySettings().allowsOurCode(protected: false) && !OverlaySettings().allowsOurCode(protected: true))
    }

    @Test("The confirmation reads as decided, French and English")
    func confirmationCopy() {
        defer { OverlayText.use(language: "en") }
        OverlayText.use(language: "fr")
        #expect(SharpeningConsent.title(game: "Deadlock") == "Activer le moteur Cartouche sur Deadlock\u{202F}?")
        #expect(SharpeningConsent.message(game: "Deadlock", antiCheat: "VAC")
                == "Deadlock utilise VAC. Notre code sera chargé dans le jeu\u{00A0}: risque de ban.")
        #expect(ot("Cancel") == "Annuler" && ot("Turn On") == "Activer" && ot("Cartouche Engine") == "Moteur Cartouche")
        OverlayText.use(language: "en")
        #expect(SharpeningConsent.title(game: "Deadlock") == "Turn On Cartouche Engine for Deadlock?")
    }

    @Test("The profile keeps the consent; an old profile has none")
    func profileCoding() throws {
        var s = OverlaySettings()
        #expect(!String(decoding: try JSONEncoder().encode(s), as: UTF8.self).contains("sharpening"))
        s.sharpening = true
        let back = try JSONDecoder().decode(OverlaySettings.self, from: try JSONEncoder().encode(s))
        #expect(back.sharpening == true)
        #expect(try JSONDecoder().decode(OverlaySettings.self, from: Data(#"{"upscale":2}"#.utf8)).sharpening == nil)
    }

    @Test("A game ships DLSS when its folder holds nvngx_dlss.dll, at any case and depth")
    func detection() throws {
        let work = try scratchDirectory("dlss")
        defer { try? FileManager.default.removeItem(at: work) }
        let deep = work.appending(path: "Engine/Plugins/DLSS/Binaries/ThirdParty/Win64")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        #expect(!GameDLSS.ships(in: work))
        try Data().write(to: deep.appending(path: "NVNGX_DLSS.DLL"))
        #expect(GameDLSS.ships(in: work))
        #expect(!GameDLSS.ships(in: work, depth: 2))
    }

    @Test("Restricted with DLSS, the menu offers Off and Temporal, our sliders wait for the consent")
    func overlayRestricted() {
        var c = OverlayContext(game: OverlayGame(id: "arena", name: "Arena", pid: 1, dlss: true, antiCheat: "Easy Anti-Cheat"), soon: [])
        #expect(c.restricted && !c.isLocked(.upscaling))
        var rows = OverlayLayout.rows(.upscaling, c)
        #expect(rows.first?.control == .segment([ot("Off"), ot("DLSS")], .upscaleBase))
        #expect(rows.first { $0.id == .upScale }?.state == .disabled(OverlayLayout.lockReason))
        c.settings.upscale = .off
        rows = OverlayLayout.rows(.upscaling, c)
        #expect(rows.first { $0.id == .upScale }?.state == .disabled(ot("Choose DLSS first")))
        SettingKey.upscaleBase.set(&c.settings, 1)
        #expect(c.settings.upscale == .temporal && SettingKey.upscaleBase.get(c.settings) == 1)
        c.settings.upscale = .spatial
        #expect(SettingKey.upscaleBase.get(c.settings) == 0, "the segment shows what runs")
        c.settings.sharpening = true
        #expect(!c.restricted && OverlayLayout.rows(.upscaling, c).allSatisfy { $0.state == .normal })
    }
}
