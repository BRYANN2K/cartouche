import AppKit
import Foundation
import SwiftUI
import Testing

@testable import NotProtonApp

@Suite("Store session expiry", .serialized)
@MainActor
struct StoreExpiryTests {

    // Signed in to Epic with Sample Free Game installed
    private func installedScene(_ label: String) async throws -> StoreScene {
        let scene = try await StoreScene(label)
        await scene.signIn(.epic, code: "epic-good-code")
        let game = try #require(scene.model.game("epic:Fennec"))
        scene.center.install(game)
        #expect(await scene.waitForJobs())
        #expect(scene.center.record("epic:Fennec") != nil)
        return scene
    }

    @Test("A token past its end at start: the store shows expired, its badge is red, installed games stay playable")
    func expiredAtStart() async throws {
        let scene = try await installedScene("expiry-start")
        defer { scene.remove() }
        // The saved user.json says the refresh token ended a minute ago
        var secret = try #require(try scene.vault.read(.epic))
        secret.files["user.json"] = Data(StoreFixtures.epicUser(refreshEnds: Date().addingTimeInterval(-60)).utf8)
        try scene.vault.write(secret, for: .epic)
        let restarted = scene.makeCenter(folders: scene.folders, vault: scene.vault, library: scene.model)
        await restarted.start(refresh: false)
        #expect(restarted.connection(.epic) == .expired(account: "player42"))
        scene.model.selection = .source(.epic)
        #expect(scene.model.badge(.source(.epic)) == "!")
        #expect(scene.model.isExpired(.source(.epic)))
        #expect(scene.model.expiredStore == .epic)
        let installed = try #require(scene.model.game("epic:Fennec"))
        let other = try #require(scene.model.game("epic:Owl"))
        #expect(installed.installed && !other.installed)
        let play = try #require(GameMenu.items(for: installed, in: scene.model).first)
        #expect(play.action == .play && !play.disabled)
        let install = try #require(GameMenu.items(for: other, in: scene.model).first)
        #expect(install.action == .install && install.disabled)
    }

    @Test("A store that refuses the token while Cartouche runs: the session turns expired, and comes back after signing in again")
    func expiredWhileRunning() async throws {
        let scene = try await installedScene("expiry-running")
        defer { scene.remove() }
        scene.flag("expired")
        await scene.center.refresh(.epic)
        #expect(scene.center.connection(.epic) == .expired(account: "player42"))
        #expect(scene.model.games(in: .source(.epic)).count == 2)
        scene.flag("expired", false)
        await scene.signIn(.epic, code: "epic-good-code")
        #expect(scene.center.connection(.epic) == .connected(account: "player42"))
        #expect(scene.model.expiredStore == nil)
    }

    @Test("An installed game still starts when the session expired: offline, without Epic's sign-in code")
    func playsWhenExpired() async throws {
        let scene = try await installedScene("expiry-play")
        defer { scene.remove() }
        scene.flag("expired")
        await scene.center.refresh(.epic)
        let game = try #require(scene.model.game("epic:Fennec"))
        GameActionRunner(model: scene.model, stores: scene.center).perform(.play, on: game)
        #expect(await scene.waitUntil { !scene.center.playing.contains(game.id) && scene.text("wine.calls").contains("Game.exe") })
        let wine = scene.text("wine.calls")
        #expect(wine.contains("Binaries/Game.exe -windowed -epicapp=Fennec"))
        #expect(!wine.contains("AUTH_PASSWORD"))
        #expect(scene.calls("legendary").contains("launch Fennec --json --no-wine --skip-version-check --offline"))
        #expect(scene.center.problem == nil)
    }

    @Test("Forced expiry in the window: the red badge, the banner and Sign In Again, in light and dark")
    func expiredWindow() async throws {
        let scene = try await installedScene("expiry-ui")
        defer { scene.remove() }
        scene.flag("expired")
        await scene.center.refresh(.epic)
        scene.model.selection = .source(.epic)
        scene.model.select("epic:Fennec")
        let compat = try await fixtureCompat(scene.work, defaults: scene.defaults)
        for dark in [false, true] {
            let view = LibraryWindow(model: scene.model, compat: compat, steamSetup: SteamSetup(defaults: scene.defaults.defaults),
                                     actions: GameActionRunner(model: scene.model, open: { _ in }, stores: scene.center))
                .environment(scene.center)
                .environment(\.covers, scene.steam.covers())
                // An offscreen capture cannot draw Liquid Glass, so the text is read off the macOS 15 look
                .environment(\.glassMode, .classic)
            let texts = try await renderedTexts(view, size: CGSize(width: 1280, height: 800), named: "store-expired-session",
                                                dark: dark, settle: 1.0)
            for wanted in ["Your Epic Games session expired", "Sign In Again", "Your games still play", "Sample Free Game", "Play"] {
                #expect(seen(texts, wanted), "\(wanted) not drawn (dark: \(dark)): \(texts)")
            }
        }
    }
}
