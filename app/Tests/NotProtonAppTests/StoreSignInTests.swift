import AppKit
import Foundation
import Security
import SwiftUI
import Testing
import WebKit

@testable import NotProtonApp

@Suite("Store sign-in", .serialized)
@MainActor
struct StoreSignInTests {

    static let epicRedirect = URL(string: "https://www.epicgames.com/id/api/redirect?clientId=34a02cf8f4414e29b15921876da36f9a&responseType=code")!

    @Test("Epic sign-in: once Epic's page hands over the code, the library lists the account's games within 15 seconds")
    func epicWithin15Seconds() async throws {
        let scene = try await StoreScene("signin-epic")
        defer { scene.remove() }
        var opened = 0
        scene.center.showSignIn = { opened += 1 }
        await scene.center.beginSignIn(.epic)
        #expect(opened == 1)
        guard case .waiting(let page)? = scene.center.signIn?.state else { Issue.record("no page"); return }
        #expect(page.url.host() == "www.epicgames.com")
        #expect(scene.model.badge(.source(.epic)) == "Sign In")
        // Any other address of Epic's page is ignored
        #expect(!scene.center.reached(URL(string: "https://www.epicgames.com/id/login")!, pageText: "Email Password"))
        let start = ContinuousClock.now
        #expect(scene.center.reached(Self.epicRedirect, pageText: #"{"authorizationCode":"epic-good-code","sid":null}"#))
        await scene.waitUntil { scene.model.games(in: .source(.epic)).count == 2 }
        let elapsed = ContinuousClock.now - start
        print("evidence: Epic games listed \(elapsed) after the code was handed over")
        #expect(elapsed < .seconds(15))
        #expect(scene.center.signIn == nil)
        #expect(scene.center.connection(.epic) == .connected(account: "player42"))
        #expect(scene.model.selection == .source(.epic))
        #expect(scene.model.games(in: .source(.epic)).map(\.name) == ["Sample Free Game", "Second Game"])
        #expect(scene.model.subtitle == "2 games. Signed in as player42")
        let listed = try #require(scene.center.lastSignIn?.listed)
        #expect(listed.timeIntervalSince(try #require(scene.center.lastSignIn?.finished)) < 15)
    }

    @Test("The token is only in the vault: no file under the stores folder holds it, including the library and game records")
    func tokenOnlyInVault() async throws {
        let scene = try await StoreScene("signin-vault", gogServer: true)
        defer { scene.remove() }
        await scene.signIn(.epic, code: "epic-good-code")
        await scene.center.beginSignIn(.gog)
        await scene.center.finishSignIn(.gog, code: "gog-good-code")
        await scene.center.beginSignIn(.amazon)
        await scene.center.finishSignIn(.amazon, code: "amazon-good-code")
        for store in StoreCenter.stores { #expect(scene.center.connection(store).isSignedIn, "\(store.name)") }
        #expect(try scene.vault.read(.gog)?.account == "galaxy_player")
        #expect(try scene.vault.read(.amazon)?.account == "Ana")
        #expect(scene.filesHolding(["epic-access", "epic-refresh", "gog-access", "gog-refresh", "encrypted-token", "amzn1.account.TEST"]).isEmpty)
        // Each run had them in place, written for the client alone
        #expect(scene.text("gogdl.saw-token").contains("gog-refresh"))
        #expect(scene.text("nile.saw-token").contains("amzn1.account.TEST"))
    }

    @Test("A failed sign-in says why and leaves the store not connected; Cancel closes it")
    func failedAndCancelled() async throws {
        let scene = try await StoreScene("signin-fail")
        defer { scene.remove() }
        await scene.center.beginSignIn(.epic)
        await scene.center.finishSignIn(.epic, code: "wrong")
        #expect(scene.center.signIn?.state == .failed("Epic Games did not accept the sign-in. Try again."))
        #expect(scene.center.connection(.epic) == .notConnected)
        #expect(try scene.vault.read(.epic) == nil)
        scene.center.cancelSignIn()
        #expect(scene.center.signIn == nil)
    }

    @Test("Sign out removes the token from the vault and asks the client to forget it")
    func signOut() async throws {
        let scene = try await StoreScene("signin-out")
        defer { scene.remove() }
        await scene.signIn(.epic, code: "epic-good-code")
        await scene.center.signOut(.epic)
        #expect(try scene.vault.read(.epic) == nil)
        #expect(scene.center.connection(.epic) == .notConnected)
        #expect(scene.calls("legendary").contains("auth --delete"))
        #expect(scene.model.screen == .signIn(.epic))
    }

    @Test("Token files left by a crash go back into the vault at the next start, and off the disk")
    func sweep() async throws {
        let vault = MemoryVault()
        let work = try scratchDirectory("vault-sweep")
        defer { try? FileManager.default.removeItem(at: work) }
        let folders = StoreFolders(root: work)
        let secrets = folders.secrets(vault: vault)
        try FileManager.default.createDirectory(at: folders.client(.amazon).appending(path: "nile"), withIntermediateDirectories: true)
        try Data("tok".utf8).write(to: folders.client(.amazon).appending(path: "nile/ab.enc"))
        try Data("{}".utf8).write(to: folders.client(.amazon).appending(path: "nile/current_user.json"))
        try Data("not a token".utf8).write(to: folders.client(.amazon).appending(path: "nile/library.json"))
        await secrets.sweep()
        #expect(try vault.read(.amazon)?.files.keys.sorted() == ["nile/ab.enc", "nile/current_user.json"])
        #expect(!FileManager.default.fileExists(atPath: folders.client(.amazon).appending(path: "nile/ab.enc").path))
        #expect(FileManager.default.fileExists(atPath: folders.client(.amazon).appending(path: "nile/library.json").path))
    }

    @Test("Runs that overlap share one copy of the tokens; the last one to end takes it back")
    func overlappingRuns() async throws {
        let vault = MemoryVault()
        let work = try scratchDirectory("vault-overlap")
        defer { try? FileManager.default.removeItem(at: work) }
        let folders = StoreFolders(root: work)
        let secrets = folders.secrets(vault: vault)
        try vault.write(StoreSecret(account: "player42", files: ["user.json": Data("one".utf8)]), for: .epic)
        let file = folders.client(.epic).appending(path: "user.json")
        let (gate, open) = AsyncStream<Void>.makeStream()
        let long = Task {
            try await secrets.using(.epic) {
                for await _ in gate { break }
            }
        }
        try await Task.sleep(for: .milliseconds(100))
        try await secrets.using(.epic) {
            #expect(FileManager.default.fileExists(atPath: file.path))
            try Data("two".utf8).write(to: file)
        }
        // The first run still needs it
        #expect(FileManager.default.fileExists(atPath: file.path))
        open.yield()
        try await long.value
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(try vault.read(.epic)?.files["user.json"] == Data("two".utf8))
        #expect(try vault.read(.epic)?.account == "player42")
        // The token file is the client's alone
        let attributes = try FileManager.default.attributesOfItem(atPath: folders.client(.epic).path)
        #expect((attributes[.posixPermissions] as? Int) == 0o700)
    }

    @Test("The Keychain item is a generic password of Cartouche's own service, this Mac only, never synced")
    func keychainItem() throws {
        let vault = KeychainVault()
        let query = vault.query(.gog)
        #expect(query[kSecClass as String] as? String == kSecClassGenericPassword as String)
        #expect(query[kSecAttrService as String] as? String == "dev.bryann2k.cartouche.store")
        #expect(query[kSecAttrAccount as String] as? String == "gog")
        let attributes = vault.attributes(Data())
        #expect(attributes[kSecAttrAccessible as String] as? String == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        #expect(attributes[kSecAttrSynchronizable as String] == nil)
    }

    @Test("No password field in Cartouche: no secure field in its code, and none in the sign-in window it draws")
    func noPasswordField() async throws {
        // In the source: no SecureField, no NSSecureTextField, no injected password input
        let sources = IdentityTests.repoRoot.appending(path: "app/Sources/NotProtonApp")
        let enumerator = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        var offenders: [String] = []
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift", let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for needle in ["SecureField", "NSSecureTextField", "type=\\\"password\\\"", "type='password'"] where text.contains(needle) {
                offenders.append("\(url.lastPathComponent): \(needle)")
            }
        }
        #expect(offenders.isEmpty, "\(offenders)")
        // The only script the sign-in window runs reads the text of Epic's code page
        let window = try String(contentsOf: sources.appending(path: "Stores/StoreSignInWindow.swift"), encoding: .utf8)
        #expect(window.components(separatedBy: "evaluateJavaScript(").count == 2)
        #expect(window.contains(#"evaluateJavaScript("document.body ? document.body.innerText : ''")"#))

        // Drawn: the store page and the sign-in window, on a local page that has a password form
        let scene = try await StoreScene("signin-nofield")
        defer { scene.remove() }
        let server = try StoreAPIServer()
        let base = try await server.start()
        defer { server.stop() }
        server.put("/login", Data(#"<html><body><form><input name="email"><input type="password" name="password"></form></body></html>"#.utf8))
        scene.center.signIn = SignInSession(store: .gog, state: .waiting(SignInPage(url: base.appending(path: "login"), codePage: nil)))
        let host = UIHost(StoreSignInWindow(center: scene.center).environment(\.glassMode, .classic), size: CGSize(width: 560, height: 700))
        defer { host.close() }
        await host.settle(1.5)
        let root = try #require(host.window.contentView)
        #expect(Self.views(in: root, of: NSSecureTextField.self).isEmpty)
        let web = try #require(Self.views(in: root, of: WKWebView.self).first)
        #expect(!web.configuration.websiteDataStore.isPersistent)
        #expect(web.url?.host() == "127.0.0.1")
        let page = StorePage(source: .epic, center: scene.center)
        let pageHost = UIHost(page, size: CGSize(width: 900, height: 800))
        defer { pageHost.close() }
        await pageHost.settle()
        #expect(Self.views(in: try #require(pageHost.window.contentView), of: NSSecureTextField.self).isEmpty)
    }

    static func views<T: NSView>(in view: NSView, of type: T.Type) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views(in: $0, of: type) }
    }
}
