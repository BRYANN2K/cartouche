import Foundation
import Testing

@testable import NotProtonApp

// The two launcher-backed stores end to end: sign-in, owned games into the library,
// installs adopted from the prefix, and launches by protocol URI. Fixtures stand in
// for the launchers' files; nothing signs in to a real account.
@Suite("Launcher adapters", .serialized)
@MainActor
struct LauncherAdapterTests {

    private func adapter(_ scene: StoreScene, _ store: GameSource) throws -> any StoreAdapter {
        try #require(scene.center.adapter(store))
    }

    private func ubisoft(_ scene: StoreScene) throws -> UbisoftAdapter {
        try #require(scene.center.adapter(.ubisoft) as? UbisoftAdapter)
    }

    private func ea(_ scene: StoreScene) throws -> EAAdapter {
        try #require(scene.center.adapter(.ea) as? EAAdapter)
    }

    // MARK: Ubisoft Connect

    @Test("Ubisoft: signing in stores the launcher's account id; owned games list from the local cache")
    func ubisoftLibrary() async throws {
        let scene = try await StoreScene("ubi-library")
        defer { scene.remove() }
        try scene.seedUbisoft()
        let ubisoft = try ubisoft(scene)
        // The cache names the signed-in account; Cartouche keeps it as the session
        #expect(await ubisoft.detectedSession() == "00000000-dead-beef-0000-000000000042")
        let account = try await ubisoft.finishSignIn(code: try #require(await ubisoft.detectedSession()))
        #expect(account == "00000000-dead-beef-0000-000000000042")
        #expect(try scene.vault.read(.ubisoft)?.account == account)
        let games = try await ubisoft.library()
        // The DLC of the fixture is not in the launcher's visible list
        #expect(games.map(\.id) == ["720", "13504"])
        #expect(games[0].title == "Anno mille huit cent")
        #expect(games[0].art?.absoluteString == "https://ubistatic3-a.akamaihd.net/orbit/uplay_launcher_3_0/assets/anno1800_thumb.png")
        #expect(games[1].title == "TRACKMANIA")
        // The session stamp tracks the cache's own write time
        let secret = try #require(try scene.vault.read(.ubisoft))
        #expect(!ubisoft.isExpired(secret, now: Date()))
        #expect(ubisoft.isExpired(secret, now: Date().addingTimeInterval(8 * 24 * 3600)))
        // No cache, no session, no games
        let empty = try await StoreScene("ubi-none")
        defer { empty.remove() }
        await #expect(throws: StoreError.self) { _ = try await self.ubisoft(empty).library() }
    }

    @Test("Ubisoft: a sealed .vdat cache still lists what the launcher's registry installed")
    func ubisoftSealedLibrary() async throws {
        let scene = try await StoreScene("ubi-sealed")
        defer { scene.remove() }
        try scene.seedUbisoft(sealed: true)
        let ubisoft = try ubisoft(scene)
        #expect(await ubisoft.detectedSession() == "00000000-dead-beef-0000-000000000042")
        let games = try await ubisoft.library()
        #expect(games.map(\.id) == ["720", "13504"])
        #expect(games.map(\.title) == ["Harbor Lords", "Far Shore"])
    }

    @Test("Ubisoft: the launcher's HTTP cache supplies the owned list the sealed .vdat cannot")
    func ubisoftSealedHTTPLibrary() async throws {
        let scene = try await StoreScene("ubi-http")
        defer { scene.remove() }
        try scene.seedUbisoft(sealed: true)
        try UbisoftCacheTests.writeHTTPBodies(into: scene.folders.launcher(.ubisoft).appending(path: "pfx"))
        let ubisoft = try ubisoft(scene)
        let games = try await ubisoft.library()
        // Editions of one space are one card — the installed product keeps the slot;
        // space-three takes the name and the art of its cached games/api card.
        #expect(games.map(\.id) == ["720", "13504", "730"])
        #expect(games.map(\.title) == ["Fixture Game One", "Fixture Game Two", "Fixture Game Three"])
        // space-one: the products body supplies the portrait candidate and the panel's
        // wide art; the launcher's tile stays the cover's last resort, never the card
        #expect(games[0].art?.absoluteString == "https://cdn.ubi.test/one-box.jpg")
        #expect(games[0].artFallback == UbisoftLocalCache.tile("space-one"))
        #expect(games[0].header?.absoluteString == "https://cdn.ubi.test/one-bg.jpg")
        // space-two has no art cached anywhere: nil cover candidate, tile as both
        // fallback and the only wide art the panel has
        #expect(games[1].art == nil && games[1].artFallback == UbisoftLocalCache.tile("space-two"))
        #expect(games[1].header == UbisoftLocalCache.tile("space-two"))
        #expect(games[2].art?.absoluteString == "https://cdn.ubi.test/box.jpg")
        #expect(games[2].header?.absoluteString == "https://cdn.ubi.test/bg.jpg")
        // The settled install names its path; the one whose folder never landed does not
        #expect(games[0].installPath?.lastPathComponent == "Harbor Lords")
        #expect(games[1].installPath == nil && games[2].installPath == nil)
    }

    @Test("Ubisoft: an install the launcher finished before Cartouche looked is adopted — record, shared prefix, Installed")
    func ubisoftAdoptedInstall() async throws {
        let scene = try await StoreScene("ubi-adopt")
        defer { scene.remove() }
        try scene.seedUbisoft(sealed: true)
        try UbisoftCacheTests.writeHTTPBodies(into: scene.folders.launcher(.ubisoft).appending(path: "pfx"))
        // Far Shore's folder is really there — the Uninstall entry said so before we looked
        let farShore = scene.folders.launcher(.ubisoft).appending(
            path: "pfx/drive_c/Program Files (x86)/Ubisoft/Ubisoft Game Launcher/games/Far Shore")
        try FileManager.default.createDirectory(at: farShore, withIntermediateDirectories: true)
        try Data("game".utf8).write(to: farShore.appending(path: "game.exe"))
        #expect(scene.center.record("ubisoft:13504") == nil)
        await scene.signIn(.ubisoft, code: "00000000-dead-beef-0000-000000000042")
        let record = try #require(scene.center.record("ubisoft:13504"))
        #expect(record.install.path == farShore)
        #expect(record.prefix.resolvingSymlinksInPath()
            == scene.folders.launcher(.ubisoft).appending(path: "pfx").resolvingSymlinksInPath())
        // The card reads Installed and offers Play; Anno's folder was already seeded
        let game = try #require(scene.model.game("ubisoft:13504"))
        #expect(game.installed && game.status() == String(localized: "Installed"))
        #expect(scene.center.record("ubisoft:720") != nil)
        // The space's third card, never installed, stays Not installed
        #expect(scene.model.game("ubisoft:730")?.installed == false)
    }

    @Test("Ubisoft: install opens uplay://install, the registry answers where it went, and the record shares the launcher's prefix")
    func ubisoftInstall() async throws {
        let scene = try await StoreScene("ubi-install")
        defer { scene.remove() }
        try scene.seedUbisoft()
        let ubisoft = try ubisoft(scene)
        let game = StoreGame(id: "720", title: "Harbor Lords")
        let record = scene.folders.gameFolder(.ubisoft, title: game.title, id: game.id)
        let install = try await ubisoft.install(game, base: record.appending(path: "game")) { _ in }
        #expect(install.path.lastPathComponent == "Harbor Lords")
        #expect(install.path.path(percentEncoded: false).contains("Ubisoft Game Launcher/games"))
        // uplay://install/720 was handed to the launcher exe
        let call = try #require(scene.calls("ubisoft.launcher").last)
        #expect(call.hasPrefix("start "))
        #expect(call.contains("UbisoftConnect.exe") && call.contains("uplay://install/720"))
        // The record's prefix resolves to the launcher's own
        #expect(record.appending(path: "pfx").resolvingSymlinksInPath()
            == scene.folders.launcher(.ubisoft).appending(path: "pfx").resolvingSymlinksInPath())
        // The launch URI uses the uplay id, not the product id
        let launch = try await ubisoft.launch(game.id, install: install, prefix: record.appending(path: "pfx"), offline: false)
        #expect(launch.executable.lastPathComponent == "UbisoftConnect.exe")
        #expect(launch.arguments == ["uplay://launch/540/0", "--in-process-gpu", "--disable-gpu"])
        // Update and verify are the launcher's own
        await #expect(throws: StoreError.self) { _ = try await ubisoft.update(game.id, install: install) { _ in } }
        await #expect(throws: StoreError.self) { _ = try await ubisoft.verify(game.id, install: install) { _ in } }
        // Uninstall goes back through the protocol, and returns once the launcher has
        // actually removed the entries and the folder — not before
        let removed = MutexBox(false)
        let removal = Task {
            try await ubisoft.uninstall(game.id, install: install)
            removed.value = true
        }
        try await Task.sleep(for: .milliseconds(80))
        #expect(!removed.value)
        #expect(scene.calls("ubisoft.launcher").last?.contains("uplay://uninstall/540") == true)
        let pfx = scene.folders.launcher(.ubisoft).appending(path: "pfx")
        try LauncherStoreTests.systemRegWithout720.write(to: pfx.appending(path: "system.reg"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: install.path)
        try await removal.value
        #expect(removed.value)
    }

    @Test("Ubisoft: install waits for the launcher's confirmation — pending entry, then Uninstall entry, error if it vanishes")
    func ubisoftInstallWaits() async throws {
        let scene = try await StoreScene("ubi-wait")
        defer { scene.remove() }
        try scene.seedUbisoft()
        let ubisoft = try ubisoft(scene)
        let pfx = scene.folders.launcher(.ubisoft).appending(path: "pfx")
        let anno = pfx.appending(path: "drive_c/Program Files (x86)/Ubisoft/Ubisoft Game Launcher/games/Harbor Lords")
        // Still downloading: the Installs entry is there, the Uninstall one is not
        try LauncherStoreTests.systemRegPending720.write(to: pfx.appending(path: "system.reg"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: anno)
        let game = StoreGame(id: "720", title: "Harbor Lords", diskBytes: 400)
        let record = scene.folders.gameFolder(.ubisoft, title: game.title, id: game.id)
        let fractions = MutexBox([Double]())
        let done = MutexBox(false)
        let task = Task { () throws -> StoreInstall in
            defer { done.value = true }
            return try await ubisoft.install(game, base: record.appending(path: "game")) { fractions.value.append($0) }
        }
        try await Task.sleep(for: .milliseconds(80))
        #expect(!done.value)   // the registry said downloading — not finished
        // The launcher confirms: the Uninstall entry lands and the folder is there and settled
        try LauncherStoreTests.systemReg.write(to: pfx.appending(path: "system.reg"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: anno, withIntermediateDirectories: true)
        let install = try await task.value
        #expect(done.value)
        #expect(install.path == anno)
        #expect(fractions.value.last == 1)
        // Aborted mid-wait: the Installs entry vanishes and nothing ever landed
        try LauncherStoreTests.systemRegPending720.write(to: pfx.appending(path: "system.reg"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: anno)
        let abort = Task { () throws -> StoreInstall in try await ubisoft.install(game, base: record.appending(path: "game")) { _ in } }
        try await Task.sleep(for: .milliseconds(60))
        try LauncherStoreTests.systemRegWithout720.write(to: pfx.appending(path: "system.reg"), atomically: true, encoding: .utf8)
        await #expect(throws: StoreError.self) { _ = try await abort.value }
        // Confirmed in the registry but the folder never lands: bounded too — no endless wait
        var impatient = ubisoft
        impatient.installPickup = 0.05
        let farShore = StoreGame(id: "13504", title: "Far Shore")
        await #expect(throws: StoreError.self) {
            _ = try await impatient.install(farShore, base: record.appending(path: "game")) { _ in }
        }
    }

    @Test("Ubisoft: uninstall is a job — the record only goes once the launcher confirms; cancelling keeps it")
    func ubisoftUninstallJob() async throws {
        let scene = try await StoreScene("ubi-uninstall")
        defer { scene.remove() }
        try scene.seedUbisoft()
        await scene.signIn(.ubisoft, code: "00000000-dead-beef-0000-000000000042")
        let game = try #require(scene.model.game("ubisoft:720"))
        scene.center.install(game)
        #expect(await scene.waitForJobs())
        let record = try #require(scene.center.record(game.id))
        scene.center.uninstall(game)
        let job = try #require(scene.center.jobs.first { $0.gameID == game.id })
        #expect(job.kind == .uninstall)
        #expect(await scene.waitUntil { scene.calls("ubisoft.launcher").last?.contains("uplay://uninstall/540") == true })
        // The launcher asks its own question: until the entries and folder are gone the record stays
        try await Task.sleep(for: .milliseconds(80))
        #expect(scene.center.record(game.id) != nil)
        #expect(FileManager.default.fileExists(atPath: record.install.path.path(percentEncoded: false)))
        // The launcher finishes its removal
        let pfx = scene.folders.launcher(.ubisoft).appending(path: "pfx")
        try LauncherStoreTests.systemRegWithout720.write(to: pfx.appending(path: "system.reg"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: record.install.path)
        #expect(await scene.waitForJobs())
        #expect(scene.center.record(game.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: record.folder.path(percentEncoded: false)))

        // Cancelled while the launcher still shows it installed: nothing was forgotten
        try LauncherStoreTests.systemReg.write(to: pfx.appending(path: "system.reg"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: record.install.path, withIntermediateDirectories: true)
        scene.center.install(game)
        #expect(await scene.waitForJobs())
        let kept = try #require(scene.center.record(game.id))
        scene.center.uninstall(game)
        let cancelling = try #require(scene.center.jobs.first { $0.gameID == game.id })
        #expect(await scene.waitUntil { scene.calls("ubisoft.launcher").last?.contains("uplay://uninstall") == true })
        try LauncherStoreTests.systemReg.write(to: pfx.appending(path: "system.reg"), atomically: true, encoding: .utf8)
        scene.center.stop(cancelling)
        #expect(await scene.waitUntil { scene.center.jobs.isEmpty })
        #expect(scene.center.record(game.id) != nil)
        #expect(FileManager.default.fileExists(atPath: kept.folder.path(percentEncoded: false)))
    }

    @Test("Ubisoft: sign-out drops the launcher's cached session, so nothing signs it back in")
    func ubisoftSignOut() async throws {
        let scene = try await StoreScene("ubi-signout")
        defer { scene.remove() }
        try scene.seedUbisoft()
        let ubisoft = try ubisoft(scene)
        #expect(await ubisoft.detectedSession() != nil)
        try await ubisoft.signOut()
        #expect(await ubisoft.detectedSession() == nil)
        #expect(throws: StoreError.self) { try UbisoftLocalCache.read(prefix: scene.folders.launcher(.ubisoft).appending(path: "pfx")) }
    }

    @Test("Shared prefix: stopping a launcher game never waits on nor kills the shared wineserver")
    func sharedPrefixStop() async throws {
        let scene = try await StoreScene("ubi-shared")
        defer { scene.remove() }
        try scene.seedUbisoft()
        await scene.signIn(.ubisoft, code: "00000000-dead-beef-0000-000000000042")
        let game = try #require(scene.model.game("ubisoft:720"))
        scene.center.install(game)
        #expect(await scene.waitForJobs())
        let record = try #require(scene.center.record(game.id))
        #expect(scene.center.launcherShared(record))
        // Play: the launch URI hands off through wine — and the prefix's wineserver
        // (also serving the launcher and any other game) is never waited on nor killed
        let serverCalls = scene.text("wineserver.calls").components(separatedBy: .newlines).count
        scene.center.play(game)
        scene.center.stopPlaying(game)
        #expect(await scene.waitUntil { !scene.center.playing.contains(game.id) })
        #expect(scene.text("wine.calls").contains("uplay://launch/540/0"))
        #expect(scene.text("wineserver.calls").components(separatedBy: .newlines).count == serverCalls)
        // A wipe request on that prefix only plays again — the launcher's files stay
        let anno = record.install.path
        scene.center.recreateBoot(game)
        #expect(FileManager.default.fileExists(atPath: anno.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: record.prefix.resolvingSymlinksInPath().path(percentEncoded: false)))
        #expect(await scene.waitUntil { !scene.center.playing.contains(game.id) })
    }

    @Test("Ubisoft: the store button opens the game's page in the launcher, or the web store without one")
    func ubisoftStorePage() async throws {
        let scene = try await StoreScene("ubi-store")
        defer { scene.remove() }
        try scene.seedUbisoft()
        var ubisoft = try ubisoft(scene)
        var opened: [URL] = []
        ubisoft.openWeb = { opened.append($0) }
        // Inside the launcher: the game's own page
        try await ubisoft.openStorePage(StoreGame(id: "720", title: "Harbor Lords"))
        #expect(scene.calls("ubisoft.launcher").last?.contains("uplay://open/game/540") == true)
        // No game: the web store
        try await ubisoft.openStorePage(nil)
        #expect(opened == [URL(string: "https://store.ubisoft.com")!])
        // The launcher itself opens bare
        _ = try await ubisoft.openLauncher()
        #expect(scene.calls("ubisoft.launcher").last?.contains("UbisoftConnect.exe") == true)
        #expect(scene.calls("ubisoft.launcher").last?.contains("uplay://") == false)
    }

    @Test("Ubisoft: sign-in opens the launcher (no WebView) and the watcher connects when the cache names the user")
    func ubisoftSignIn() async throws {
        let scene = try await StoreScene("ubi-signin")
        defer { scene.remove() }
        try scene.seedUbisoft()
        scene.center.sessionPollInterval = 0.02
        await scene.center.beginSignIn(.ubisoft)
        guard case .waiting(let page) = scene.center.signIn?.state else { Issue.record("sign-in did not wait"); return }
        // The launcher was opened for the user to sign into — the page says no WebView
        #expect(scene.calls("ubisoft.launcher").last?.contains("UbisoftConnect.exe") == true)
        #expect(page.viaLauncher)
        // No URL ever yields a code by itself
        #expect(!scene.center.reached(URL(string: "uplay://launch/540/0")!, pageText: nil))
        // The watcher reads the cache's account and finishes on its own
        #expect(await scene.waitUntil { scene.center.connection(.ubisoft).isSignedIn })
        #expect(scene.center.connection(.ubisoft) == .connected(account: "00000000-dead-beef-0000-000000000042"))
        #expect(await scene.waitUntil { scene.model.games(in: .source(.ubisoft)).count == 2 })
        #expect(scene.model.games(in: .source(.ubisoft)).map(\.name) == ["Anno mille huit cent", "TRACKMANIA"])
        #expect(scene.model.selection == .source(.ubisoft))
    }

    @Test("Ubisoft: with no launcher session the wait can be cancelled, and ends on its own at the timeout")
    func ubisoftSignInWaits() async throws {
        let scene = try await StoreScene("ubi-wait-signin")
        defer { scene.remove() }
        // The launcher is there but no account ever signed in: exe + registry, no cache
        let pfx = scene.folders.launcher(.ubisoft).appending(path: "pfx")
        let exe = pfx.appending(path: "drive_c/Program Files (x86)/Ubisoft/Ubisoft Game Launcher/UbisoftConnect.exe")
        try FileManager.default.createDirectory(at: exe.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: exe.path(percentEncoded: false), contents: Data("MZ".utf8))
        try LauncherStoreTests.systemReg.write(to: pfx.appending(path: "system.reg"), atomically: true, encoding: .utf8)
        scene.center.sessionPollInterval = 0.02
        await scene.center.beginSignIn(.ubisoft)
        guard case .waiting(let page) = scene.center.signIn?.state else { Issue.record("sign-in did not wait"); return }
        #expect(page.viaLauncher)
        // Still waiting after several polls: nothing landed in the cache
        try await Task.sleep(for: .milliseconds(90))
        #expect(scene.center.connection(.ubisoft) == .waiting)
        scene.center.cancelSignIn()
        #expect(scene.center.connection(.ubisoft) == .notConnected)
        // Without a cancel it times out on its own
        scene.center.sessionPollTimeout = 0.05
        await scene.center.beginSignIn(.ubisoft)
        #expect(await scene.waitUntil {
            if case .failed = scene.center.signIn?.state { true } else { false }
        })
        scene.center.cancelSignIn()
    }

    // MARK: EA app

    @Test("EA: signing in adopts the launcher's session into the vault; the library maps owned products and legacy titles")
    func eaSignInLibrary() async throws {
        let scene = try await StoreScene("ea-signin", gogServer: true)
        defer { scene.remove() }
        scene.serveEA()
        try scene.seedEASession()
        let ea = try ea(scene)
        // The launcher opened for the user's own sign-in: no WebView, no loopback page
        let page = try await ea.signInPage()
        #expect(page.viaLauncher)
        let call = try #require(scene.calls("ea.launcher").last)
        #expect(call.hasPrefix("start-drained ") && call.contains("EADesktop.exe"))
        // No URL hands over a code by itself — the session file is the proof
        #expect(ea.code(at: URL(string: "http://127.0.0.1:31033/success?code=x")!, pageText: nil) == nil)
        let account = try await ea.finishSignIn(code: try #require(await ea.detectedSession()))
        #expect(account == "Player One")
        let secret = try #require(try scene.vault.read(.ea))
        #expect(secret.files.keys.sorted() == ["token.json"])
        // The token is only in the vault: the adopted session file was scrubbed
        #expect(scene.filesHolding(["ea-access", "ea-refresh"]).isEmpty)
        let games = try await ea.library()
        #expect(games.map(\.id) == ["Origin.OFR.50.00040000", "Origin.OFR.50.00040002", "OFR.legacy-1"])
        // The bearer rode along on every call; nothing hit disk after the run
        #expect(scene.server?.requests.filter { $0.path == "/graphql" }.allSatisfy { $0.authorization == "Bearer ea-access" } == true)
        #expect(scene.filesHolding(["ea-access", "ea-refresh"]).isEmpty)
        // With no session to adopt, finishSignIn sends the user back to the launcher
        let empty = try await StoreScene("ea-none")
        defer { empty.remove() }
        await #expect(throws: StoreError.self) { _ = try await self.ea(empty).finishSignIn(code: "anything") }
    }

    @Test("EA: sign-in waits on the launcher session — the watcher connects once it appears")
    func eaSignIn() async throws {
        let scene = try await StoreScene("ea-watch", gogServer: true)
        defer { scene.remove() }
        scene.serveEA()
        // Installed but nobody signed in yet: the exe is there, no session file
        let exe = scene.folders.launcher(.ea).appending(
            path: "pfx/drive_c/Program Files/Electronic Arts/EA Desktop/EA Desktop/EADesktop.exe")
        try FileManager.default.createDirectory(at: exe.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: exe.path(percentEncoded: false), contents: Data("MZ".utf8))
        scene.center.sessionPollInterval = 0.02
        await scene.center.beginSignIn(.ea)
        guard case .waiting(let page) = scene.center.signIn?.state else { Issue.record("sign-in did not wait"); return }
        #expect(page.viaLauncher)
        #expect(scene.calls("ea.launcher").last?.contains("EADesktop.exe") == true)
        // Nothing signed in: still waiting after several polls
        try await Task.sleep(for: .milliseconds(90))
        #expect(scene.center.connection(.ea) == .waiting)
        // The user signs in inside the EA app: the session file lands and the watcher adopts it
        try scene.seedEASession()
        #expect(await scene.waitUntil { scene.center.connection(.ea).isSignedIn })
        #expect(scene.center.connection(.ea) == .connected(account: "Player One"))
        #expect(await scene.waitUntil { scene.model.games(in: .source(.ea)).count == 3 })
        #expect(scene.model.selection == .source(.ea))
    }

    @Test("EA: sign-out scrubs the launcher's session files, so nothing adopts it back")
    func eaSignOut() async throws {
        let scene = try await StoreScene("ea-signout")
        defer { scene.remove() }
        try scene.seedEASession()
        let ea = try ea(scene)
        #expect(await ea.detectedSession() != nil)
        try await ea.signOut()
        #expect(await ea.detectedSession() == nil)
        #expect(scene.filesHolding(["ea-access", "ea-refresh"]).isEmpty)
    }

    @Test("EA: an expired access token refreshes silently inside the run; a dead refresh token ends the session")
    func eaRefresh() async throws {
        let scene = try await StoreScene("ea-refresh", gogServer: true)
        defer { scene.remove() }
        scene.serveEA()
        try scene.seedEASession()
        let ea = try ea(scene)
        _ = try await ea.finishSignIn(code: try #require(await ea.detectedSession()))
        // The saved access token is now stale: the next library() must refresh it first
        let token = EAToken(accessToken: "ea-stale", refreshToken: "ea-refresh",
                            expiresAt: Date().addingTimeInterval(-60), refreshExpiresAt: Date().addingTimeInterval(360_000))
        try scene.vault.write(StoreSecret(account: "Player One", files: ["token.json": try token.json()]), for: .ea)
        let games = try await ea.library()
        #expect(!games.isEmpty)
        // The refreshed token went back into the vault, not just the run
        let saved = try #require(try scene.vault.read(.ea))
        #expect(EAToken.read(saved.files["token.json"]!)?.accessToken == "ea-access")
        // A refused refresh is an expired session, and isExpired agrees from the dates
        scene.flag("ea-dead-refresh")
        let stale = EAToken(accessToken: "ea-stale", refreshToken: "ea-refresh",
                            expiresAt: Date().addingTimeInterval(-60), refreshExpiresAt: Date().addingTimeInterval(360_000))
        try scene.vault.write(StoreSecret(account: "Player One", files: ["token.json": try stale.json()]), for: .ea)
        await #expect(throws: StoreError.sessionExpired) { _ = try await ea.library() }
        #expect(ea.isExpired(StoreSecret(account: "p", files: ["token.json": Data()]), now: Date()) == false)
        let dead = EAToken(accessToken: "a", refreshToken: "r", expiresAt: Date(), refreshExpiresAt: Date().addingTimeInterval(-1))
        #expect(ea.isExpired(StoreSecret(account: "p", files: ["token.json": try dead.json()]), now: Date()))
    }

    @Test("EA: install opens origin2://…&autoDownload, the game lands where installerdata.xml says, launch is the protocol URI")
    func eaInstallLaunch() async throws {
        let scene = try await StoreScene("ea-install")
        defer { scene.remove() }
        try scene.seedEA()
        let ea = try ea(scene)
        let game = StoreGame(id: "Origin.OFR.50.00040000", title: "Sample EA Game")
        let record = scene.folders.gameFolder(.ea, title: game.title, id: game.id)
        let install = try await ea.install(game, base: record.appending(path: "game")) { _ in }
        #expect(install.path.lastPathComponent == "Sample EA Game")
        let call = try #require(scene.calls("ea.launcher").last)
        // B7: drained stderr, never /dev/null nor an unread pipe, and the wbemprox trace is on
        #expect(call.hasPrefix("start-drained "))
        #expect(call.contains("EADesktop.exe") && call.contains("origin2://game/launch?offerIds=Origin.OFR.50.00040000&autoDownload=1"))
        #expect(record.appending(path: "pfx").resolvingSymlinksInPath()
            == scene.folders.launcher(.ea).appending(path: "pfx").resolvingSymlinksInPath())
        let launch = try await ea.launch(game.id, install: install, prefix: record.appending(path: "pfx"), offline: false)
        #expect(launch.executable.lastPathComponent == "EADesktop.exe")
        #expect(launch.arguments == ["origin2://game/launch?offerIds=Origin.OFR.50.00040000"])
        await #expect(throws: StoreError.self) { try await ea.uninstall(game.id, install: install) }
        await #expect(throws: StoreError.self) { _ = try await ea.update(game.id, install: install) { _ in } }
    }

    @Test("EA: the store button opens the game's web page from its slug")
    func eaStorePage() async throws {
        let scene = try await StoreScene("ea-store", gogServer: true)
        defer { scene.remove() }
        scene.serveEA()
        try scene.seedEASession()
        var ea = try ea(scene)
        _ = try await ea.finishSignIn(code: try #require(await ea.detectedSession()))
        let games = try await ea.library()
        var opened: [URL] = []
        ea.openWeb = { opened.append($0) }
        try await ea.openStorePage(games[0])
        #expect(opened == [URL(string: "https://www.ea.com/games/sample-ea-game")!])
        try await ea.openStorePage(nil)
        #expect(opened.last == URL(string: "https://www.ea.com/games"))
    }

    @Test("EA: the launcher's own session can be adopted instead of a sign-in")
    func eaAdopt() async throws {
        let scene = try await StoreScene("ea-adopt")
        defer { scene.remove() }
        let ea = try ea(scene)
        #expect(try await ea.adoptLauncherSession() == false)
        let sessions = scene.folders.launcher(.ea)
            .appending(path: "pfx/drive_c/ProgramData/EA Desktop")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try Data(#"{"access_token": "ea-session", "refresh_token": "ea-session-refresh", "expires_in": 3599}"#.utf8)
            .write(to: sessions.appending(path: "session.json"))
        #expect(try await ea.adoptLauncherSession() == true)
        let secret = try #require(try scene.vault.read(.ea))
        #expect(EAToken.read(secret.files["token.json"]!)?.accessToken == "ea-session")
        #expect(scene.filesHolding(["ea-session", "ea-session-refresh"]).isEmpty)
    }

    @Test("EA off the single switch: listed but unavailable — no sign-in, no install, no launcher")
    func eaDisabled() async throws {
        let scene = try await StoreScene("ea-off", gogServer: true)
        defer { scene.remove() }
        scene.serveEA()
        var ea = try ea(scene)
        ea.enabled = false
        scene.center.replace(ea, for: .ea)
        #expect(!ea.isAvailable)
                await #expect(throws: StoreError.self) { try await ea.signInPage() }
        await #expect(throws: StoreError.self) { try await ea.finishSignIn(code: "ea-good-code") }
        await #expect(throws: StoreError.self) { try await ea.adoptLauncherSession() }
        // Disabled, the launcher's session file is never even read
        try scene.seedEASession()
        #expect(await ea.detectedSession() == nil)
        await #expect(throws: StoreError.self) {
            _ = try await ea.install(StoreGame(id: "x", title: "X"), base: scene.folders.root.appending(path: "g/game")) { _ in }
        }
        await #expect(throws: StoreError.self) { _ = try await ea.openLauncher() }
        await #expect(throws: StoreError.self) { try await ea.openStorePage(nil) }
        // Disabled is a hard stop for the token and the network, even with a session in the vault:
        // library() never reads it, isExpired never opens it, start() never sees it.
        await #expect(throws: StoreError.self) { _ = try await ea.library() }
        let live = EAToken(accessToken: "ea-access", refreshToken: "ea-refresh",
                           expiresAt: Date().addingTimeInterval(3600), refreshExpiresAt: Date().addingTimeInterval(360_000))
        try scene.vault.write(StoreSecret(account: "Player One", files: ["token.json": try live.json()]), for: .ea)
        #expect(ea.isExpired(try #require(try scene.vault.read(.ea)), now: Date()) == false)
        let requests = scene.server?.requests.count ?? 0
        await scene.center.start(refresh: true)
        #expect(scene.center.connection(.ea) == .notConnected)
        #expect(scene.server?.requests.count == requests)
        // StoreCenter's copy carries the same flag
        #expect((scene.center.adapter(.ea) as? EAAdapter)?.isAvailable == false)
    }

    @Test("StoreAdapter surface: availability, launcher, store page and session probe are requirements")
    func protocolSurface() async throws {
        let scene = try await StoreScene("adapter-surface")
        defer { scene.remove() }
        try scene.seedUbisoft()
        // Through the protocol itself, not the concrete type
        let adapter: any StoreAdapter = try #require(scene.center.adapter(.ubisoft))
        #expect(adapter.isAvailable)
        _ = try await adapter.openLauncher()
        #expect(scene.calls("ubisoft.launcher").last?.contains("UbisoftConnect.exe") == true)
        try await adapter.openStorePage(StoreGame(id: "720", title: "Harbor Lords"))
        #expect(scene.calls("ubisoft.launcher").last?.contains("uplay://open/game/540") == true)
        #expect(await adapter.detectedSession() == "00000000-dead-beef-0000-000000000042")
    }

    // MARK: Both

    @Test("Both stores feed the library like the others: games visible when signed in, hidden before")
    func libraryFeeds() async throws {
        let scene = try await StoreScene("launcher-feed", gogServer: true)
        defer { scene.remove() }
        try scene.seedUbisoft()
        scene.serveEA()
        await scene.center.start(refresh: false)
        // Not connected: nothing shows from either launcher store
        let before = scene.model.games(in: .all).count
        #expect(scene.model.games(in: .source(.ubisoft)).isEmpty && scene.model.games(in: .source(.ea)).isEmpty)
        #expect(scene.model.badge(.source(.ubisoft)) == "Sign In")
        #expect(scene.model.badge(.source(.ea)) == "Sign In")
        await scene.signIn(.ubisoft, code: "00000000-dead-beef-0000-000000000042")
        await scene.signIn(.ea, code: "ea-good-code")
        #expect(await scene.waitUntil { scene.model.games(in: .all).count == before + 5 })
        #expect(scene.model.games(in: .source(.ubisoft)).count == 2)
        #expect(scene.model.games(in: .source(.ea)).count == 3)
        #expect(scene.model.isConnected(.ubisoft) && scene.model.isConnected(.ea))
        #expect(scene.model.account(for: .ea) == "Player One")
    }
}
