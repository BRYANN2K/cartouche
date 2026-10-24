import AppKit
import Foundation
import SwiftUI
import Testing

@testable import NotProtonApp

// The store pages and Settings > Accounts as drawn, in light and dark, with the
// macOS 15 look as well. PNGs go to CARTOUCHE_SNAPSHOTS when it is set.
@Suite("Store screens", .serialized)
@MainActor
struct StoreUITests {

    @Test("Amazon Games' page lists cloud saves and online features as Not supported yet, as nile 1.2.0 has neither")
    func amazonPage() async throws {
        let scene = try await StoreScene("ui-amazon")
        defer { scene.remove() }
        for mode in [GlassMode.liquid, .classic] {
            for dark in [false, true] {
                let view = StorePage(source: .amazon, center: scene.center).environment(\.glassMode, mode)
                let texts = try await renderedTexts(view, size: CGSize(width: 900, height: 820),
                                                    named: mode == .classic ? "store-page-amazon-macos15" : "store-page-amazon", dark: dark)
                for wanted in ["Connect Amazon Games", "Sign In with Amazon Games", "Games download with nile", "What works",
                               "Download, update and verify games", "Cloud saves", "Online features", "Keychain"] {
                    #expect(seen(texts, wanted), "\(wanted) not drawn (dark: \(dark)): \(texts)")
                }
                #expect(texts.filter { $0.contains("Not supported yet") }.count == 2, "\(texts)")
            }
        }
    }

    @Test("Epic Games' and GOG's pages say what their clients support")
    func epicAndGOGPages() async throws {
        let scene = try await StoreScene("ui-epic-gog")
        defer { scene.remove() }
        for (store, client, online) in [(GameSource.epic, "legendary", "Depends on the game"),
                                        (.gog, "gogdl and comet", "Achievements and friends, through comet")] {
            let texts = try await renderedTexts(StorePage(source: store, center: scene.center), size: CGSize(width: 900, height: 820),
                                                named: "store-page-\(store.id)")
            #expect(seen(texts, "Games download with \(client)"), "\(texts)")
            #expect(seen(texts, "Supported"), "\(texts)")
            #expect(seen(texts, online), "\(texts)")
            #expect(!texts.contains { $0.contains("Not supported yet") }, "\(texts)")
        }
    }

    @Test("While the store's page is open, its page in the library waits for the sign-in")
    func waiting() async throws {
        let scene = try await StoreScene("ui-waiting")
        defer { scene.remove() }
        await scene.center.beginSignIn(.epic)
        let texts = try await renderedTexts(StorePage(source: .epic, center: scene.center), size: CGSize(width: 900, height: 820),
                                            named: "store-page-waiting")
        #expect(seen(texts, "Waiting for sign-in"), "\(texts)")
    }

    @Test("Settings > Accounts: Sign In, Sign Out and Sign In Again per store")
    func accounts() async throws {
        let scene = try await StoreScene("ui-accounts")
        defer { scene.remove() }
        await scene.signIn(.epic, code: "epic-good-code")
        await scene.center.beginSignIn(.amazon)
        await scene.center.finishSignIn(.amazon, code: "amazon-good-code")
        scene.flag("expired")
        await scene.center.refresh(.amazon)
        for dark in [false, true] {
            let view = AccountsSettingsView(model: scene.model).environment(scene.center)
            let texts = try await renderedTexts(view, size: CGSize(width: 640, height: 420), named: "settings-accounts-stores", dark: dark)
            for wanted in ["Signed in as player42", "Sign Out", "Not connected", "Sign In", "Your Amazon Games session expired",
                           "Sign In Again", "Import Games", "Keychain"] {
                #expect(seen(texts, wanted), "\(wanted) not drawn (dark: \(dark)): \(texts)")
            }
        }
    }
}
