import Foundation
import Testing

@testable import NotProtonApp

// Each adapter against its client's recorded answers: the arguments it passes, what
// it reads back, and that tokens only exist on disk while a client runs
@Suite("Store adapters", .serialized)
@MainActor
struct StoreAdapterTests {

    private func adapter(_ scene: StoreScene, _ store: GameSource) throws -> any StoreAdapter {
        try #require(scene.center.adapter(store))
    }

    // MARK: Epic, legendary

    @Test("Epic: the sign-in page is Epic's, and the code is read only from Epic's redirect page")
    func epicCode() async throws {
        let scene = try await StoreScene("epic-code")
        defer { scene.remove() }
        let epic = try adapter(scene, .epic)
        let page = try await epic.signInPage()
        #expect(page.url.absoluteString.hasPrefix("https://www.epicgames.com/id/login?redirectUrl="))
        #expect(page.url.absoluteString.contains("34a02cf8f4414e29b15921876da36f9a"))
        let redirect = URL(string: "https://www.epicgames.com/id/api/redirect?clientId=34a02cf8f4414e29b15921876da36f9a&responseType=code")!
        #expect(page.isCodePage(redirect))
        #expect(!page.isCodePage(URL(string: "https://www.epicgames.com/id/login")!))
        let json = #"{"warning":"Do not share this code","redirectUrl":"https://localhost/launcher/authorized?code=abc","authorizationCode":"abc","sid":null}"#
        #expect(epic.code(at: redirect, pageText: json) == "abc")
        #expect(epic.code(at: URL(string: "https://evil.example/id/api/redirect")!, pageText: json) == nil)
        #expect(epic.code(at: redirect, pageText: "<html>Sign in</html>") == nil)
    }

    @Test("Epic: legendary trades the code for user.json, which goes to the vault and leaves the disk")
    func epicSignIn() async throws {
        let scene = try await StoreScene("epic-sign-in")
        defer { scene.remove() }
        let epic = try adapter(scene, .epic)
        let name = try await epic.finishSignIn(code: "epic-good-code")
        #expect(name == "player42")
        #expect(scene.calls("legendary").first == "auth --code epic-good-code")
        let secret = try #require(try scene.vault.read(.epic))
        #expect(secret.files.keys.sorted() == ["user.json"])
        #expect(scene.filesHolding(["epic-access", "epic-refresh"]).isEmpty)
        await #expect(throws: StoreError.self) { try await epic.finishSignIn(code: "wrong") }
    }

    @Test("Epic: the library lists Windows games with their tall box art and cloud saves; the token is back in place for the run")
    func epicLibrary() async throws {
        let scene = try await StoreScene("epic-library")
        defer { scene.remove() }
        let epic = try adapter(scene, .epic)
        _ = try await epic.finishSignIn(code: "epic-good-code")
        let games = try await epic.library()
        #expect(games.map(\.id) == ["Fennec", "Owl"])
        #expect(games[0].title == "Sample Free Game")
        #expect(games[0].art == URL(string: "https://cdn1.epicgames.com/tall.jpg"))
        #expect(games[0].cloudSaves && !games[1].cloudSaves)
        #expect(scene.text("legendary.saw-token").contains("epic-refresh"))
        #expect(scene.filesHolding(["epic-access", "epic-refresh"]).isEmpty)
    }

    @Test("Epic: install, update, verify, launch and uninstall pass legendary 0.21.1's flags")
    func epicGame() async throws {
        let scene = try await StoreScene("epic-game")
        defer { scene.remove() }
        let epic = try adapter(scene, .epic)
        _ = try await epic.finishSignIn(code: "epic-good-code")
        let base = scene.work.appending(path: "games")
        let seen = LineLog()
        let install = try await epic.install(StoreGame(id: "Fennec", title: "Sample Free Game"), base: base) { seen.add(String($0)) }
        #expect(seen.all == ["0.125", "0.5", "1.0"])
        #expect(install.path.path(percentEncoded: false).hasPrefix(base.path(percentEncoded: false)))
        #expect(install.version == "1.0.1")
        _ = try await epic.update("Fennec", install: install) { _ in }
        try await epic.verify("Fennec", install: install) { _ in }
        let prefix = scene.work.appending(path: "pfx")
        let launch = try await epic.launch("Fennec", install: install, prefix: prefix, offline: false)
        #expect(launch.executable == install.path.appending(path: "Binaries/Game.exe"))
        #expect(launch.arguments == ["-windowed", "-AUTH_PASSWORD=exchange-code", "-epicapp=Fennec"])
        #expect(launch.workingDirectory.lastPathComponent == "Binaries")
        #expect(launch.environment == ["EOS_TEST": "1"])
        try await epic.uninstall("Fennec", install: install)
        let calls = scene.calls("legendary")
        #expect(calls.contains("-y install Fennec --base-path \(base.path(percentEncoded: false)) --platform Windows --skip-sdl"))
        #expect(calls.contains("-y install Fennec --update-only --skip-sdl"))
        #expect(calls.contains("-y install Fennec --repair --skip-sdl"))
        #expect(calls.contains("launch Fennec --json --no-wine --skip-version-check"))
        #expect(calls.contains("-y uninstall Fennec --skip-uninstaller"))
    }

    @Test("Epic: a refused login is an expired session; the game still launches offline")
    func epicExpired() async throws {
        let scene = try await StoreScene("epic-expired")
        defer { scene.remove() }
        let epic = try adapter(scene, .epic)
        _ = try await epic.finishSignIn(code: "epic-good-code")
        let install = try await epic.install(StoreGame(id: "Fennec", title: "Sample Free Game"), base: scene.work.appending(path: "g")) { _ in }
        scene.flag("expired")
        await #expect(throws: StoreError.sessionExpired) { _ = try await epic.library() }
        await #expect(throws: StoreError.sessionExpired) {
            _ = try await epic.launch("Fennec", install: install, prefix: scene.work, offline: false)
        }
        let offline = try await epic.launch("Fennec", install: install, prefix: scene.work, offline: true)
        #expect(!offline.arguments.contains { $0.hasPrefix("-AUTH_PASSWORD") })
        // user.json's refresh_expires_at in the past says so without asking Epic
        let past = StoreSecret(account: "player42", files: ["user.json": Data(StoreFixtures.epicUser(refreshEnds: Date().addingTimeInterval(-60)).utf8)])
        #expect(epic.isExpired(past, now: Date()))
        #expect(!epic.isExpired(try #require(try scene.vault.read(.epic)), now: Date()))
    }

    @Test("Epic: the cloud save folder is resolved inside the game's prefix and synced each way")
    func epicSaves() async throws {
        let scene = try await StoreScene("epic-saves")
        defer { scene.remove() }
        let epic = try adapter(scene, .epic)
        _ = try await epic.finishSignIn(code: "epic-good-code")
        _ = try await epic.library()
        let install = StoreInstall(path: scene.work.appending(path: "Fennec"))
        let prefix = scene.work.appending(path: "pfx")
        try FileManager.default.createDirectory(at: prefix.appending(path: "drive_c/users/crossover"), withIntermediateDirectories: true)
        let locations = try await epic.saveLocations("Fennec", install: install, prefix: prefix)
        #expect(locations.map(\.path) == [prefix.appending(path: "drive_c/users/crossover/AppData/Local/SampleGame/Saved/abc123")])
        _ = try await epic.syncSaves("Fennec", locations: locations, direction: .download, stamps: [:])
        _ = try await epic.syncSaves("Fennec", locations: locations, direction: .upload, stamps: [:])
        let saves = scene.text("legendary.saves")
        #expect(saves.contains("Fennec --save-path \(locations[0].path.path(percentEncoded: false)) --skip-upload"))
        #expect(saves.contains("--skip-download"))
        #expect(EpicAdapter.savePath("{installdir}/../../etc", install: install.path, prefix: prefix, accountID: nil)
            == install.path.appending(path: "etc"))
    }

    // MARK: GOG, gogdl and comet

    @Test("GOG: the code comes from embed.gog.com's address; gogdl saves auth.json, the vault keeps it")
    func gogSignIn() async throws {
        let scene = try await StoreScene("gog-sign-in", gogServer: true)
        defer { scene.remove() }
        let gog = try adapter(scene, .gog)
        let page = try await gog.signInPage()
        #expect(page.url.host() == "auth.gog.com" && page.codePage == nil)
        #expect(gog.code(at: URL(string: "https://embed.gog.com/on_login_success?origin=client&code=gog-good-code")!, pageText: nil) == "gog-good-code")
        #expect(gog.code(at: URL(string: "https://example.com/on_login_success?code=x")!, pageText: nil) == nil)
        let name = try await gog.finishSignIn(code: "gog-good-code")
        #expect(name == "galaxy_player")
        #expect(scene.server?.requests.first { $0.path == "/userData.json" }?.authorization == "Bearer gog-access")
        #expect(try scene.vault.read(.gog)?.files.keys.sorted() == [GOGAdapter.authFile])
        #expect(scene.filesHolding(["gog-access", "gog-refresh"]).isEmpty)
        await #expect(throws: StoreError.self) { _ = try await gog.finishSignIn(code: "wrong") }
    }

    @Test("GOG: every page of the library, Windows games only, with GOG's portrait cover")
    func gogLibrary() async throws {
        let scene = try await StoreScene("gog-library", gogServer: true)
        defer { scene.remove() }
        let gog = try adapter(scene, .gog)
        _ = try await gog.finishSignIn(code: "gog-good-code")
        let games = try await gog.library()
        #expect(games == [StoreGame(id: "1207658924", title: "Sample GOG Game")])
        let pages = scene.server?.requests.filter { $0.path.hasPrefix("/account/getFilteredProducts") }
        #expect(pages?.count == 2)
        #expect(pages?.allSatisfy { $0.authorization == "Bearer gog-access" } == true)
        #expect(await gog.artURL(games[0]) == URL(string: "https://images.gog.com/cover.jpg"))
        scene.flag("expired")
        await #expect(throws: StoreError.sessionExpired) { _ = try await gog.library() }
    }

    @Test("GOG: gogdl downloads the Windows build; the game starts from its goggame info; comet runs beside it")
    func gogGame() async throws {
        let scene = try await StoreScene("gog-game", gogServer: true)
        defer { scene.remove() }
        let gog = try adapter(scene, .gog)
        _ = try await gog.finishSignIn(code: "gog-good-code")
        let base = scene.work.appending(path: "games")
        let install = try await gog.install(StoreGame(id: "1207658924", title: "Sample GOG Game"), base: base) { _ in }
        #expect(install.path == base.appending(path: "Sample GOG Game", directoryHint: .isDirectory))
        #expect(install.version == "5310700")
        let launch = try await gog.launch("1207658924", install: install, prefix: scene.work, offline: false)
        #expect(launch.executable == install.path.appending(path: "bin/game.exe"))
        #expect(launch.arguments == ["-skipintro"])
        let comet = try #require(try await gog.companion("1207658924"))
        #expect(comet.arguments == ["--from-heroic", "--username", "player", "--quit"])
        #expect(comet.environment["HOME"] == scene.folders.home(.gog).path(percentEncoded: false))
        let calls = scene.calls("gogdl")
        let auth = scene.folders.home(.gog).appending(path: GOGAdapter.authFile).path(percentEncoded: false)
        #expect(calls.contains("--auth-config-path \(auth) download 1207658924 --platform windows --path \(base.path(percentEncoded: false)) --skip-dlcs"))
    }

    @Test("GOG: save locations from GOG's remote config, in the prefix; gogdl's sync time is kept")
    func gogSaves() async throws {
        let scene = try await StoreScene("gog-saves", gogServer: true)
        defer { scene.remove() }
        let gog = try adapter(scene, .gog)
        _ = try await gog.finishSignIn(code: "gog-good-code")
        let install = try await gog.install(StoreGame(id: "1207658924", title: "Sample GOG Game"), base: scene.work.appending(path: "g")) { _ in }
        let prefix = scene.work.appending(path: "pfx")
        try FileManager.default.createDirectory(at: prefix.appending(path: "drive_c/users/crossover"), withIntermediateDirectories: true)
        let locations = try await gog.saveLocations("1207658924", install: install, prefix: prefix)
        #expect(locations == [SaveLocation(name: "saves", path: prefix.appending(path: "drive_c/users/crossover/Documents/Sample GOG Game/Saves"))])
        let stamps = try await gog.syncSaves("1207658924", locations: locations, direction: .download, stamps: [:])
        #expect(stamps == ["saves": "1790000123.5"])
        #expect(scene.text("gogdl.saves").contains("--os windows --ts 0 --name saves --skip-upload"))
        #expect(GOGAdapter.resolve("<?UNKNOWN?>/x", install: install.path, prefix: prefix) == nil)
    }

    // MARK: Amazon, nile

    @Test("Amazon: nile prepares the page; the code comes back on amazon.com; nile registers the device")
    func amazonSignIn() async throws {
        let scene = try await StoreScene("amazon-sign-in")
        defer { scene.remove() }
        let amazon = try adapter(scene, .amazon)
        let page = try await amazon.signInPage()
        #expect(page.url.absoluteString == "https://www.amazon.com/ap/signin?openid.oa2.client_id=device:414d415a4f4e")
        let back = URL(string: "https://www.amazon.com/?openid.assoc_handle=amzn_sonic_games_launcher&openid.oa2.authorization_code=amazon-good-code")!
        #expect(amazon.code(at: back, pageText: nil) == "amazon-good-code")
        #expect(amazon.code(at: URL(string: "https://amazon.com.evil.example/?openid.oa2.authorization_code=x")!, pageText: nil) == nil)
        #expect(try await amazon.finishSignIn(code: "amazon-good-code") == "Ana")
        #expect(scene.calls("nile").contains("register --code amazon-good-code --client-id 414d415a4f4e --code-verifier verifier-1 --serial SERIAL1"))
        #expect(try scene.vault.read(.amazon)?.files.keys.sorted() == ["nile/0a1b2c.enc", "nile/current_user.json"])
        #expect(scene.filesHolding(["encrypted-token", "amzn1.account.TEST"]).isEmpty)
    }

    @Test("Amazon: nile 1.2.0 has no cloud saves and no online support, and the page says so")
    func amazonCapabilities() async throws {
        let scene = try await StoreScene("amazon-caps")
        defer { scene.remove() }
        let caps = try adapter(scene, .amazon).capabilities
        #expect(!caps.cloudSaves && caps.online == .notSupported)
        #expect(caps.cloudSavesLabel == "Not supported yet" && caps.onlineLabel == "Not supported yet")
        #expect(try adapter(scene, .epic).capabilities.cloudSavesLabel == "Supported")
        #expect(try adapter(scene, .gog).capabilities.onlineLabel == "Achievements and friends, through comet")
    }

    @Test("Amazon: the library, install with progress, and the game started from fuel.json")
    func amazonGame() async throws {
        let scene = try await StoreScene("amazon-game")
        defer { scene.remove() }
        let amazon = try adapter(scene, .amazon)
        _ = try await amazon.signInPage()
        _ = try await amazon.finishSignIn(code: "amazon-good-code")
        let games = try await amazon.library()
        #expect(games.map(\.title) == ["Sample Amazon Game", "Other Prime Game"])
        #expect(games[0].art == URL(string: "https://m.media-amazon.com/icon.png"))
        let seen = LineLog()
        let install = try await amazon.install(games[0], base: scene.work.appending(path: "g")) { seen.add(String($0)) }
        #expect(seen.all == ["0.4", "1.0"])
        let launch = try await amazon.launch(games[0].id, install: install, prefix: scene.work, offline: true)
        #expect(launch.executable == install.path.appending(path: "Game/Sample.exe"))
        #expect(launch.arguments == ["-prime"])
        #expect(scene.calls("nile").contains("library sync"))
        #expect(scene.calls("nile").contains("library list --json"))
    }
}
