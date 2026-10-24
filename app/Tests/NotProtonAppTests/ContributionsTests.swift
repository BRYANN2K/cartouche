import CryptoKit
import Foundation
import RetroArchKit
import Testing

@testable import NotProtonApp

// Shared with the site: backend/test/fixtures/contributions in the site repository holds the same files.
enum ContributionFixtures {
    static let folder = CompatFixture.repo.appending(path: "docs/schema/contributions")

    static func data(_ name: String) throws -> Data { try Data(contentsOf: folder.appending(path: name)) }
    static func json(_ name: String) throws -> JSONValue { try CanonicalJSON.parse(data(name)) }

    static func keys() throws -> TrustedFixKeys {
        let key = try json("fix-public-key.json")
        let raw = try #require(Data(base64Encoded: key["ed25519_raw_base64"]?.string ?? ""))
        return TrustedFixKeys(keys: [key["key_id"]!.string!: try Curve25519.Signing.PublicKey(rawRepresentation: raw)])
    }

    static let reviewed = ContributionAdapter.date("2026-10-22T18:00:00Z")!
    static let cs2GameID = "d4b5e1b3-0d7b-4f8c-a5a1-1a1a1a1a1a1a"
}

final class FakeSite: @unchecked Sendable {
    struct Seen: Sendable {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data?
    }

    private let lock = NSLock()
    private var answers: [Result<(Int, String, [String: String]), URLError>]
    private(set) var seen: [Seen] = []

    init(_ answers: [Result<(Int, String, [String: String]), URLError>]) { self.answers = answers }

    var client: ContributionClient {
        var c = ContributionClient(base: URL(string: "https://community.test")!)
        c.cooldown = HTTPCooldown()
        c.transport = { [self] request in try self.answer(request) }
        return c
    }

    func answer(_ request: URLRequest) throws -> (Data, Int, [String: String]) {
        try lock.withLock {
            seen.append(Seen(method: request.httpMethod ?? "GET", path: request.url?.path() ?? "",
                             headers: request.allHTTPHeaderFields ?? [:], body: request.httpBody))
            guard !answers.isEmpty else { throw URLError(.notConnectedToInternet) }
            let (status, body, headers) = try answers.removeFirst().get()
            return (Data(body.utf8), status, headers)
        }
    }
}

struct MemoryContributorStore: ContributorStore {
    final class Box: @unchecked Sendable {
        var value: ContributionClient.Credential?
        var failWrites = false
        var failReads = false
    }

    let box = Box()

    func read() throws -> ContributionClient.Credential? {
        if box.failReads { throw URLError(.cannotDecodeContentData) }
        return box.value
    }

    func write(_ credential: ContributionClient.Credential) throws {
        if box.failWrites { throw URLError(.cannotCreateFile) }
        box.value = credential
    }

    func delete() throws { box.value = nil }
}

@Suite("Contribution contract")
struct ContributionContractTests {

    let game = ContributionGame(store: "steam", storeID: "730", title: "Counter-Strike 2")
    let mac = MacInfo(model: "Mac16,8", chip: "M4 Pro", cpuCores: 14, ramGB: 24, macOS: "26.0.1")

    func session() -> StoredSession {
        var measured = PlayStats.Measured(seconds: 1200, frames: 70080)
        measured.histogram = [20: 12, 60: 1188]
        measured.width = 1920
        measured.height = 1080
        return StoredSession(
            appID: 730, setup: PlaySetup(runnerID: "cx-26.3.0", translation: .rosetta, backend: .dxmt),
            runnerName: "CrossOver Wine 26.3 · CrossOver", started: ContributionAdapter.date("2026-10-20T18:00:00Z")!,
            ended: ContributionAdapter.date("2026-10-20T18:30:00Z")!, measurement: .on, measured: measured)
    }

    @Test("A measured session becomes the shared fixture, with second buckets and no 1% low")
    func measuredSession() throws {
        var draft = ReportDraft.from(session: session(), game: game, excludedSeconds: 45)
        draft.outcome = .playable
        draft.shareStatistics = true
        let body = try ContributionWire.encode(ContributionAdapter.report(draft, mac: mac, appVersion: "0.1.0"))
        #expect(CanonicalJSON.string(try CanonicalJSON.parse(body))
            == CanonicalJSON.string(try ContributionFixtures.json("report-app-measured.json")))
        #expect(!String(decoding: body, as: UTF8.self).contains("low_1_percent"))
    }

    @Test("Without consent no hardware or FPS leaves, and the report is manual")
    func noStatistics() throws {
        var draft = ReportDraft.from(session: session(), game: game, excludedSeconds: 45)
        draft.shareStatistics = false
        let report = ContributionAdapter.report(draft, mac: mac, appVersion: "0.1.0")
        #expect(report.configuration.mac == nil)
        #expect(report.performance == nil)
        #expect(report.configuration.resolution == nil)
        #expect(report.origin == "manual")
        #expect(report.consent.shareStatistics == false)
    }

    @Test("A launch failure without FPS, with the anti-cheat asked only when the game has one")
    func manualReport() throws {
        var draft = ReportDraft(game: game, method: .wine, runner: "CrossOver Wine 26.3", runnerBuild: "cx-26.3.0",
                                translation: .rosetta, backend: .d3dmetal,
                                observedAt: ContributionAdapter.date("2026-10-21T09:00:00Z")!)
        draft.outcome = .doesNotLaunch
        draft.comment = "  Black screen after the launcher.  "
        draft.antiCheatNames = ["VAC"]
        draft.antiCheat = .init(mode: .protectedMatchmaking, result: .notTested, names: [])
        let body = try ContributionWire.encode(ContributionAdapter.report(draft, mac: mac, appVersion: "0.1.0"))
        #expect(CanonicalJSON.string(try CanonicalJSON.parse(body))
            == CanonicalJSON.string(try ContributionFixtures.json("report-manual-no-statistics.json")))
        draft.antiCheatNames = []
        #expect(ContributionAdapter.report(draft, mac: mac, appVersion: "0.1.0").anticheat == nil)
    }

    @Test("Unknown values stay unknown: no game build is invented and odd labels are left out")
    func unknownStaysUnknown() {
        var draft = ReportDraft.from(session: session(), game: game, excludedSeconds: nil)
        draft.runner = "Wine · build/with/slashes"
        let report = ContributionAdapter.report(draft, mac: MacInfo(model: nil, chip: nil, cpuCores: nil, ramGB: 16, macOS: "26.0"),
                                                appVersion: "0.1.0")
        #expect(report.configuration.gameBuild == nil)
        #expect(report.configuration.runner == nil)
        #expect(report.configuration.mac == nil)
        #expect(report.performance == nil || report.performance?.excludedSeconds == nil)
    }

    @Test("A fix proposal carries only allowlisted settings and an empty build list when the build is unknown")
    func recipe() throws {
        var draft = FixDraft(game: game, values: .init(backend: "dxmt", translation: "rosetta"), runnerBuild: "cx-26.3.0",
                             backend: "dxmt", gameBuild: "16234567")
        draft.title = "DXMT fixes the black screen"
        draft.problem = "black screen"
        #expect(draft.missing.isEmpty)
        let recipe = draft.recipe()
        #expect(recipe.appliesTo.gameBuilds == ["16234567"])
        #expect(recipe.operations == [.init(values: .init(backend: "dxmt", translation: "rosetta"))])
        draft.gameBuild = nil
        #expect(draft.recipe().appliesTo.gameBuilds == [])
        let fixture = try JSONDecoder().decode(ContributionWire.Recipe.self, from: ContributionFixtures.data("recipe.json"))
        #expect(fixture.operations == recipe.operations)
        #expect(FixDraft(game: game, values: .init(), runnerBuild: nil, backend: "dxmt").missing == [.title, .problem, .settings, .runner])
    }

    @Test("Store identity is exact; an installer game's Steam match needs confirmation")
    func identity() {
        #expect(ContributionGame.resolve(.steam(730, name: "CS2", installed: true)) == .exact(game.withTitle("CS2")))
        var installer = Game(id: "installer:abc", source: .installer, name: "Some Game", installed: true)
        #expect(ContributionGame.resolve(installer) == .unknown)
        installer.compatAppID = 42
        #expect(ContributionGame.resolve(installer)
            == .needsConfirmation(ContributionGame(store: "steam", storeID: "42", title: "Some Game")))
        let epic = Game(id: "epic:fn:fortnite", source: .epic, name: "Fortnite", installed: true)
        #expect(ContributionGame.resolve(epic) == .exact(ContributionGame(store: "epic", storeID: "fn:fortnite", title: "Fortnite")))
    }

    @Test("Canonical JSON matches JavaScript's JSON.stringify for strings and numbers")
    func canonical() {
        #expect(CanonicalJSON.string(["b": 1, "a": ["x\n\"é\u{01}", .bool(true), .null]]) == #"{"a":["x\n\"é\u0001",true,null],"b":1}"#)
        #expect(CanonicalJSON.number(58.4) == "58.4")
        #expect(CanonicalJSON.number(1e21) == "1e+21")
        #expect(CanonicalJSON.number(0.000001) == "0.000001")
        #expect(CanonicalJSON.number(1e-7) == "1e-7")
        #expect(CanonicalJSON.number(-0.5) == "-0.5")
        #expect(CanonicalJSON.number(123456789012) == "123456789012")
    }
}

extension ContributionGame {
    func withTitle(_ title: String) -> ContributionGame { ContributionGame(store: store, storeID: storeID, title: title) }
}

@Suite("Contribution queue")
struct ContributionQueueTests {

    let game = ContributionGame(store: "steam", storeID: "730", title: "Counter-Strike 2")
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func confirmed(_ body: String = #"{"a":1}"#) -> ContributionItem {
        var item = ContributionItem(kind: .report, game: game, summary: "CS2", body: Data(body.utf8))
        ContributionQueue.confirm(&item)
        return item
    }

    @Test("A draft is never sent, and confirming gives it a key that a resend keeps")
    func keys() {
        var item = ContributionItem(kind: .report, game: game, summary: "CS2", body: Data("{}".utf8))
        #expect(ContributionQueue.due([item], now: now).isEmpty)
        ContributionQueue.confirm(&item)
        let key = item.idempotencyKey
        #expect(key?.hasPrefix("cartouche-") == true)
        item.transport = .failed
        ContributionQueue.confirm(&item)
        #expect(item.idempotencyKey == key)
        ContributionQueue.edit(&item, body: Data(#"{"changed":true}"#.utf8), summary: "CS2")
        #expect(item.transport == .draft)
        ContributionQueue.confirm(&item)
        #expect(item.idempotencyKey != key)
    }

    @Test("A network cut after the server stored the report resends the same key and settles on one report")
    func replay() async {
        let site = FakeSite([
            .failure(URLError(.networkConnectionLost)),
            .success((200, #"{"id":"r1","status":"pending","replayed":true}"#, [:])),
        ])
        let sender = ContributionSender(client: site.client)
        let item = confirmed()
        guard case .later(let waiting) = await sender.send(item, token: "t", now: now, own: { nil }) else {
            Issue.record("expected a retry"); return
        }
        #expect(waiting.nextAttempt == now.addingTimeInterval(30))
        guard case .received(let done) = await sender.send(waiting, token: "t", now: now, own: { nil }) else {
            Issue.record("expected the replay"); return
        }
        #expect(done.remoteID == "r1")
        #expect(done.transport == .received)
        #expect(done.moderation == .pending)
        #expect(site.seen.map { $0.headers["Idempotency-Key"] } == [item.idempotencyKey, item.idempotencyKey])
        #expect(site.seen.allSatisfy { $0.path == "/api/v1/games/steam:730/reports" && $0.headers["Authorization"] == "Bearer t" })
    }

    @Test("429 waits for Retry-After; a refused payload fails without retrying")
    func throttling() async {
        let site = FakeSite([
            .success((429, #"{"error":{"code":"quota"}}"#, ["retry-after": "600"])),
            .success((400, #"{"error":{"code":"invalid_request"}}"#, [:])),
        ])
        let sender = ContributionSender(client: site.client)
        guard case .later(let waiting) = await sender.send(confirmed(), token: "t", now: now, own: { nil }) else {
            Issue.record("expected a pause"); return
        }
        #expect((waiting.nextAttempt ?? now).timeIntervalSince(now) >= 600)
        // While the host is paused nothing goes out
        guard case .later = await sender.send(waiting, token: "t", now: now, own: { nil }) else {
            Issue.record("expected the pause to hold"); return
        }
        #expect(site.seen.count == 1)
        let later = ContributionSender(client: site.client)
        guard case .failed(let failed) = await later.send(waiting, token: "t", now: now, own: { nil }) else {
            Issue.record("expected a failure"); return
        }
        #expect(failed.lastError == "invalid_request")
        #expect(ContributionQueue.due([failed], now: now.addingTimeInterval(86400)).isEmpty)
    }

    @Test("A replayed withdrawal that the server already applied is settled from the author's list")
    func withdrawalReplay() async {
        let site = FakeSite([.success((409, #"{"error":{"code":"version_conflict"}}"#, [:]))])
        var item = ContributionItem(kind: .reportWithdrawal, game: game, summary: "CS2", remoteID: "r1", remoteVersion: 2)
        ContributionQueue.confirm(&item)
        let result = await ContributionSender(client: site.client).send(item, token: "t", now: now) {
            ([ContributionClient.OwnReport(id: "r1", gameID: "g", status: "withdrawn", version: 3, payload: nil)], [])
        }
        guard case .received(let done) = result else { Issue.record("expected settled"); return }
        #expect(done.moderation == .withdrawn)
        #expect(site.seen.first?.headers["If-Match"] == "2")
    }

    @Test("A missing game proposes it to the moderators and waits a day")
    func missingGame() async {
        let site = FakeSite([
            .success((404, #"{"error":{"code":"game_not_found"}}"#, [:])),
            .success((202, #"{"id":"p1","status":"pending"}"#, [:])),
        ])
        guard case .later(let waiting) = await ContributionSender(client: site.client).send(confirmed(), token: "t", now: now, own: { nil })
        else { Issue.record("expected later"); return }
        #expect(site.seen.map(\.path) == ["/api/v1/games/steam:730/reports", "/api/v1/game-proposals"])
        #expect(waiting.nextAttempt == now.addingTimeInterval(86400))
    }

    @Test("The queue survives a restart; sending items come back confirmed")
    func persistence() throws {
        let file = ContributionQueueFile(file: try scratchDirectory("queue").appending(path: "queue.json"))
        try file.save([confirmed()])
        let loaded = file.load()
        #expect(loaded.count == 1)
        #expect(loaded[0].transport == .confirmed)
    }
}

@Suite("Contributor identity")
struct ContributorIdentityTests {

    @Test("Created once, kept in the store, reused")
    func createdOnce() async throws {
        let site = FakeSite([.success((201, #"{"contributor_id":"c1","token":"secret","warning":"x"}"#, [:]))])
        let store = MemoryContributorStore()
        let identity = ContributorIdentity(store: store)
        let first = try await identity.credential(client: site.client)
        let second = try await identity.credential(client: site.client)
        #expect(first == second)
        #expect(store.box.value?.token == "secret")
        #expect(site.seen.count == 1)
    }

    @Test("An unreadable Keychain never creates a new contributor")
    func keychainFailure() async {
        let site = FakeSite([])
        let store = MemoryContributorStore()
        store.box.failReads = true
        await #expect(throws: ContributorIdentity.Problem.keychainUnreadable) {
            try await ContributorIdentity(store: store).credential(client: site.client)
        }
        #expect(site.seen.isEmpty)
    }

    @Test("A failed creation waits before the next attempt; a refused key is replaced once")
    func noLoop() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let site = FakeSite([
            .failure(URLError(.notConnectedToInternet)),
            .success((201, #"{"contributor_id":"c1","token":"a"}"#, [:])),
            .success((201, #"{"contributor_id":"c2","token":"b"}"#, [:])),
        ])
        let store = MemoryContributorStore()
        let identity = ContributorIdentity(store: store)
        await #expect(throws: ContributorIdentity.Problem.client(.offline)) { try await identity.credential(client: site.client, now: now) }
        await #expect(throws: ContributorIdentity.Problem.waiting(until: now.addingTimeInterval(900))) {
            try await identity.credential(client: site.client, now: now.addingTimeInterval(60))
        }
        let a = try await identity.credential(client: site.client, now: now.addingTimeInterval(901))
        #expect(await identity.refused(a))
        let b = try await identity.credential(client: site.client, now: now.addingTimeInterval(902))
        #expect(b.token == "b")
        #expect(await identity.refused(b) == false)
    }

    @Test("A Keychain that cannot keep the key still lets this session send")
    func unsaved() async throws {
        let site = FakeSite([.success((201, #"{"contributor_id":"c1","token":"a"}"#, [:]))])
        let store = MemoryContributorStore()
        store.box.failWrites = true
        let identity = ContributorIdentity(store: store)
        _ = try await identity.credential(client: site.client)
        #expect(await identity.isUnsaved)
    }
}

@Suite("Fix verification")
struct FixVerificationTests {

    func registry(now: Date = ContributionFixtures.reviewed, last: Int = 0) throws -> VerifiedRegistry {
        try FixVerifier.registry(ContributionFixtures.data("fix-registry.json"), keys: ContributionFixtures.keys(), now: now, lastVersion: last)
    }

    func gameID() throws -> String { try ContributionFixtures.json("fix-artifact.json")["payload"]!["game_id"]!.string! }

    @Test("The site's signed registry and artifact verify with the pinned key")
    func valid() throws {
        let r = try registry()
        #expect(r.version == 7)
        #expect(r.isRevoked("9d8c7b6a-5f4e-4d3c-8b2a-0f1e2d3c4b5a", 2))
        let fix = try FixVerifier.artifact(ContributionFixtures.data("fix-artifact.json"), registry: r,
                                           keys: ContributionFixtures.keys(), gameID: gameID(), now: ContributionFixtures.reviewed)
        #expect(fix.recipe.title == "DXMT fixes the black screen")
        #expect(fix.recipe.description.contains("café"))
    }

    @Test("Expiry, rollback, an unknown key, a tampered payload and another game are refused")
    func refusals() throws {
        let keys = try ContributionFixtures.keys()
        #expect(throws: FixVerifier.Refusal.expired) { try registry(now: ContributionFixtures.reviewed.addingTimeInterval(86400)) }
        #expect(throws: FixVerifier.Refusal.rolledBack) { try registry(last: 8) }
        #expect(throws: FixVerifier.Refusal.noTrustedKey) {
            try FixVerifier.registry(ContributionFixtures.data("fix-registry.json"), keys: TrustedFixKeys(keys: [:]),
                                     now: ContributionFixtures.reviewed, lastVersion: 0)
        }
        let other = TrustedFixKeys(keys: ["cartouche-fixes-test": Curve25519.Signing.PrivateKey().publicKey])
        #expect(throws: FixVerifier.Refusal.badSignature) {
            try FixVerifier.registry(ContributionFixtures.data("fix-registry.json"), keys: other, now: ContributionFixtures.reviewed, lastVersion: 0)
        }
        let text = String(decoding: try ContributionFixtures.data("fix-artifact.json"), as: UTF8.self)
        let tampered = Data(text.replacingOccurrences(of: "\"dxmt\"", with: "\"dxvk\"").utf8)
        #expect(throws: FixVerifier.Refusal.badSignature) {
            try FixVerifier.artifact(tampered, registry: registry(), keys: keys, gameID: gameID(), now: ContributionFixtures.reviewed)
        }
        #expect(throws: FixVerifier.Refusal.otherGame) {
            try FixVerifier.artifact(ContributionFixtures.data("fix-artifact.json"), registry: registry(), keys: keys,
                                     gameID: "00000000-0000-4000-a000-000000000000", now: ContributionFixtures.reviewed)
        }
        var r = try registry()
        r = VerifiedRegistry(version: r.version, expires: r.expires, fixes: r.fixes,
                             revoked: r.revoked.union(["\(r.fixes[0].id)#1"]))
        #expect(throws: FixVerifier.Refusal.revoked) {
            try FixVerifier.artifact(ContributionFixtures.data("fix-artifact.json"), registry: r, keys: keys, gameID: gameID(),
                                     now: ContributionFixtures.reviewed)
        }
        let unlisted = VerifiedRegistry(version: 7, expires: r.expires, fixes: [], revoked: [])
        #expect(throws: FixVerifier.Refusal.notListed) {
            try FixVerifier.artifact(ContributionFixtures.data("fix-artifact.json"), registry: unlisted, keys: keys, gameID: gameID(),
                                     now: ContributionFixtures.reviewed)
        }
    }

    @Test("A fix applies only to its runner, backend and build; Undo restores the exact setup")
    func planAndUndo() throws {
        let fix = try FixVerifier.artifact(ContributionFixtures.data("fix-artifact.json"), registry: registry(),
                                           keys: ContributionFixtures.keys(), gameID: gameID(), now: ContributionFixtures.reviewed)
        let runner = Runner(id: "cx-26.3.0", kind: .crossOver, version: "26.3.0", displayVersion: "26.3", flavors: [.rosetta],
                            state: .ready, build: SupportedRunners.all[0], source: nil, isInstalled: true)
        let resolved = GameSetup(version: .windows, runner: runner, translation: .rosetta, backend: .d3dmetal, environment: [:], metalHUD: false)
        let before = GameSetupChoice(runnerID: "cx-26.3.0", graphics: .d3dmetal, environment: ["DXMT_LOG": "1"])
        let plan = FixPlan.make(fix, choice: before, resolved: resolved, offered: [.d3dmetal, .dxmt], hasMacBuild: false,
                                gameBuild: "16234567")
        #expect(plan.canApply)
        #expect(plan.after.graphics == .dxmt)
        #expect(plan.after.environment == before.environment)
        #expect(FixPlan.make(fix, choice: before, resolved: resolved, offered: [.d3dmetal], hasMacBuild: false, gameBuild: "16234567")
            .mismatches == [.backendNotOffered])
        #expect(FixPlan.make(fix, choice: before, resolved: resolved, offered: [.dxmt], hasMacBuild: false, gameBuild: nil)
            .mismatches == [.unknownGameBuild])
        #expect(FixPlan.make(fix, choice: before, resolved: resolved, offered: [.dxmt], hasMacBuild: false, gameBuild: "1")
            .mismatches == [.gameBuild])

        let store = AppliedFixStore(file: try scratchDirectory("applied").appending(path: "applied.json"))
        var current = before
        try FixApplication.apply(plan, fix: fix, gameID: "steam:730", store: store, now: .now) { current = $0 }
        #expect(current == plan.after)
        try FixApplication.undo(gameID: "steam:730", store: store) { current = $0 }
        #expect(current == before)
        #expect(store.load().isEmpty)
    }
}

@Suite("Compatibility resolution")
struct CompatResolutionTests {

    static func feed(_ games: String, usable: String = "2026-11-05T00:00:00Z") throws -> CommunityFeed {
        try CommunityFeed.read(Data("""
            {"schema":"cartouche-app-feed","schema_version":1,"generated_at":"2026-10-22T00:00:00.000Z",
             "refresh_after":"2026-10-23T00:00:00.000Z","usable_until":"\(usable)","sources":[],"games":[\(games)]}
            """.utf8))
    }

    static let cs2 = """
        {"id":"g1","title":"Counter-Strike 2","stores":[{"store":"steam","store_id":"730"}],
         "declarations":{"native":null,"wine":{"method":"wine","label":"Compatible","tone":"good","source":"CrossOver 26.3.0 · CodeWeavers",
           "protected_online":"compatible","mode_exceptions":[{"mode":"FACEIT","status":"unsupported-on-macos","notes":"Windows only"}]}},
         "anticheat":{"state":"present","names":["VAC"],"sources":[]},"cohorts":[],
         "fixes":[{"id":"f1","revision":1},{"id":"f2","revision":1}],"revoked_fixes":[{"id":"f2","revision":1}]}
        """

    let now = ContributionAdapter.date("2026-10-22T12:00:00Z")!

    @Test("Cartouche data comes first, with the site's declaration, its exceptions and revocations")
    func cartoucheFirst() throws {
        let r = ResolvedCompatibility.resolve(feed: try Self.feed(Self.cs2), ref: "steam:730", method: .wine, legacy: nil, now: now)
        #expect(r.origin == .cartouche)
        #expect(r.statement?.verdict == .compatible)
        #expect(r.statement?.exceptions.first?.mode == "FACEIT")
        #expect(r.antiCheat == .present(["VAC"]))
        #expect(r.macOnline == .compatible)
        #expect(r.fixes == [.init(id: "f1", revision: 1)])
        #expect(r.showsLinuxBlock(nil) == false)
    }

    @Test("Players' results take precedence over the declaration")
    func players() throws {
        let cohort = """
            {"configuration":{"method":"wine"},"measurement_method":null,"anticheat_mode":"protected-matchmaking","contributors":1,
             "sessions":1,"median_fps":null,"outcomes":{"does-not-launch":1},"anticheat_results":{"failure":1},"conflicting":false,
             "confidence":"isolated","last_tested_at":"2026-10-20T00:00:00Z","expires_at":"2027-04-01T00:00:00Z"}
            """
        let game = Self.cs2.replacingOccurrences(of: #""cohorts":[]"#, with: #""cohorts":[\#(cohort)]"#)
        let r = ResolvedCompatibility.resolve(feed: try Self.feed(game), ref: "steam:730", method: .wine, legacy: nil, now: now)
        #expect(r.statement?.verdict == .needsFix)
        #expect(r.macOnline == .blocked)
        let native = ResolvedCompatibility.resolve(feed: try Self.feed(game), ref: "steam:730", method: .native, legacy: nil, now: now)
        #expect(native.cohorts.isEmpty)
        #expect(native.statement == nil)
    }

    @Test("Without a usable feed, compat.json fills only what is missing, labelled as Linux evidence")
    func fallback() throws {
        let legacy = try CompatFixture.data().record(appID: 1245620)
        let expired = try Self.feed(Self.cs2, usable: "2026-10-21T00:00:00Z")
        let r = ResolvedCompatibility.resolve(feed: expired, ref: "steam:1245620", method: .wine, legacy: legacy, now: now)
        #expect(r.origin == .legacy)
        #expect(r.statement == nil)
        let none = ResolvedCompatibility.resolve(feed: nil, ref: nil, method: .wine, legacy: nil, now: now)
        #expect(none.origin == .none)
        #expect(none.antiCheat == .unknown)
    }

    @Test("An explicit absence is not overwritten by the legacy data")
    func absence() throws {
        let game = Self.cs2.replacingOccurrences(of: #""state":"present","names":["VAC"]"#, with: #""state":"absent","names":[]"#)
        let legacy = try CompatFixture.data().record(appID: 1245620)
        let r = ResolvedCompatibility.resolve(feed: try Self.feed(game), ref: "steam:730", method: .wine, legacy: legacy, now: now)
        #expect(r.antiCheat == .absent)
    }

    @Test("An unknown feed format is refused and the last valid copy stays")
    func format() async throws {
        let dir = try scratchDirectory("feed")
        let body = Data(#"{"schema":"cartouche-app-feed","schema_version":2,"games":[]}"#.utf8)
        let client = CommunityFeedClient(directory: dir) { body }
        let current = try Self.feed(Self.cs2)
        let (outcome, fresh) = await client.refresh(now: now.addingTimeInterval(86400 * 2), current: current)
        guard case .rejected = outcome else { Issue.record("expected rejected"); return }
        #expect(fresh == nil)
    }
}
