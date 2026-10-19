import Foundation
import Testing

@testable import NotProtonApp

// The fixture is the builder's output for the recorded 2026-10-19 answers, kept
// current by tools/compat/tests/test_build.py.
enum CompatFixture {
    static let repo = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    static let gzip = repo.appending(path: "tools/compat/fixtures/compat-2026-10-19.json.gz")
    static let generated = CompatDate.instant("2026-10-19T03:17:00Z")!

    static func packed() throws -> Data { try Data(contentsOf: gzip) }
    static func json() throws -> String { String(decoding: try Gzip.decompress(packed()), as: UTF8.self) }
    static func data() throws -> CompatData { try CompatData.read(packed(), schema: .bundled()) }

    // MacGamingDB's recorded answer for Elden Ring. The app reads MacGamingDB live; this
    // answer is never published.
    static let eldenRingAnswer = repo.appending(path: "tools/compat/fixtures/2026-10-19/macgamingdb/games/1245620.json")
    static func eldenRingMac() throws -> MacGamingDBEntry { try MacGamingDBEntry.parse(Data(contentsOf: eldenRingAnswer)) }
}

@Suite("Compatibility data client")
struct CompatibilityClientTests {

    // Answers the client's requests from a script and counts them
    private final class Server: @unchecked Sendable {
        private let lock = NSLock()
        private var answers: [Result<(Data, Int), Error>]
        private(set) var asked = 0

        init(_ answers: [Result<(Data, Int), Error>]) { self.answers = answers }

        func fetch(_ url: URL) throws -> (Data, Int) {
            lock.lock(); defer { lock.unlock() }
            asked += 1
            return try answers.removeFirst().get()
        }
    }

    private static let offline: Result<(Data, Int), Error> = .failure(URLError(.notConnectedToInternet))

    private func client(_ work: URL, _ server: Server) -> CompatibilityClient {
        var client = CompatibilityClient(directory: work.appending(path: "compatibility"))
        client.feed = URL(string: "https://example.invalid/compat.json.gz")
        client.fetch = { url in try server.fetch(url) }
        return client
    }

    private func seedCache(_ client: CompatibilityClient) throws {
        try FileManager.default.createDirectory(at: client.directory, withIntermediateDirectories: true)
        try CompatFixture.packed().write(to: client.cacheFile)
    }

    @Test("The bundled schema is docs/schema/compat.schema.json")
    func bundledSchemaIsTheDocumentedOne() throws {
        let url = try #require(Bundle.module.url(forResource: "compat.schema", withExtension: "json"))
        #expect(try Data(contentsOf: url)
            == Data(contentsOf: CompatFixture.repo.appending(path: "docs/schema/compat.schema.json")))
    }

    @Test("The file comes from the compat-data release of the repository serving the Sparkle feed")
    func feedAddress() throws {
        let plist = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: CompatFixture.repo.appending(path: "app/Info.plist")), format: nil)
        let appcast = try #require((plist as? [String: Any])?["SUFeedURL"] as? String)
        let appcastURL = try #require(URL(string: appcast))
        let feed = try #require(CompatibilityClient.feed(fromAppcast: appcastURL))
        #expect(feed.absoluteString == appcast.replacingOccurrences(
            of: "/releases/latest/download/appcast.xml", with: "/releases/download/compat-data/compat.json.gz"))
        #expect(feed.absoluteString.hasSuffix("/releases/download/compat-data/compat.json.gz"))
        #expect(CompatibilityClient.feed(fromAppcast: URL(string: "https://example.org/appcast.xml")!) == nil)
        #expect(CompatibilityClient.feed(fromAppcast: URL(string: "https://github.com/a/b/releases")!) == nil)
    }

    @Test("The fixture build reads and matches the schema")
    func fixtureReads() throws {
        let data = try CompatFixture.data()
        #expect(data.generated == CompatFixture.generated)
        #expect(data.records.count == 4)
        #expect(data.record(appID: 1245620)?.applegamingwiki?.ratings["crossover"] == "playable")
        #expect(try !CompatFixture.json().lowercased().contains("macgamingdb"))
        #expect(data.record(appID: 1172470)?.protondb?.verdict == .doesntRun)
        #expect(data.record(appID: 1172470)?.areweanticheatyet?.anticheats == ["Easy Anti-Cheat", "Hyperion"])
    }

    @Test("Offline with a cached copy: the cache is used and its age is shown")
    @MainActor
    func offlineLaunch() async throws {
        let work = try scratchDirectory("compat-offline")
        defer { try? FileManager.default.removeItem(at: work) }
        let server = Server([Self.offline])
        let client = client(work, server)
        try seedCache(client)

        let model = CompatibilityModel(client: client)
        model.now = { CompatFixture.generated.addingTimeInterval(5 * 86400 + 600) }
        let outcome = await model.refresh()

        guard case .offline = outcome else { Issue.record("expected offline, got \(String(describing: outcome))"); return }
        #expect(model.isOffline)
        #expect(model.record(appID: 1245620)?.name == "Elden Ring")
        #expect(model.ageNotice == "Offline. Compatibility data from 5 days ago.")
        #expect(server.asked == 1)
    }

    @Test("Data up to 3 days old shows no age")
    func ageThreshold() {
        let start = CompatFixture.generated
        #expect(CompatibilityAge.notice(generated: start, now: start.addingTimeInterval(3 * 86400 + 3600), offline: true) == nil)
        #expect(CompatibilityAge.notice(generated: start, now: start.addingTimeInterval(4 * 86400), offline: true)
            == "Offline. Compatibility data from 4 days ago.")
        #expect(CompatibilityAge.notice(generated: start, now: start.addingTimeInterval(9 * 86400), offline: false)
            == "Compatibility data from 9 days ago.")
    }

    @Test("Offline with no cache: no data and no age")
    @MainActor
    func offlineWithoutCache() async throws {
        let work = try scratchDirectory("compat-empty")
        defer { try? FileManager.default.removeItem(at: work) }
        let model = CompatibilityModel(client: client(work, Server([Self.offline])))
        await model.refresh()
        #expect(model.data == nil)
        #expect(model.ageNotice == nil)
    }

    @Test("A download that fails validation is discarded and the previous copy stays", arguments: [
        "truncated gzip", "damaged gzip", "not JSON", "schema break", "older file",
    ])
    @MainActor
    func corruptDownload(kind: String) async throws {
        let work = try scratchDirectory("compat-corrupt")
        defer { try? FileManager.default.removeItem(at: work) }
        let packed = try CompatFixture.packed()
        let json = try CompatFixture.json()
        let body: Data = switch kind {
        case "truncated gzip": packed.prefix(packed.count / 2)
        case "damaged gzip": Data(packed.enumerated().map { $0.offset == packed.count / 2 ? ~$0.element : $0.element })
        case "not JSON": Data("<html>rate limited</html>".utf8)
        case "schema break": Data(json.replacingOccurrences(of: "\"verdict\":\"doesnt_run\"", with: "\"verdict\":\"borked\"").utf8)
        default: Data(json.replacingOccurrences(of: "2026-10-19T03:17:00Z", with: "2026-10-12T03:17:00Z").utf8)
        }
        let server = Server([.success((body, 200))])
        let client = client(work, server)
        try seedCache(client)

        let model = CompatibilityModel(client: client)
        model.now = { CompatFixture.generated.addingTimeInterval(86400) }
        model.load()
        let outcome = await model.refresh()

        guard case .rejected = outcome else { Issue.record("\(kind): got \(String(describing: outcome))"); return }
        #expect(try Data(contentsOf: client.cacheFile) == packed)
        #expect(model.data?.generated == CompatFixture.generated)
        #expect(model.record(appID: 1172470)?.protondb?.verdict == .doesntRun)
    }

    @Test("A valid download replaces the cache")
    @MainActor
    func validDownload() async throws {
        let work = try scratchDirectory("compat-valid")
        defer { try? FileManager.default.removeItem(at: work) }
        let newer = Data(try CompatFixture.json()
            .replacingOccurrences(of: "2026-10-19T03:17:00Z", with: "2026-10-20T03:17:00Z").utf8)
        let client = client(work, Server([.success((newer, 200))]))
        try seedCache(client)

        let model = CompatibilityModel(client: client)
        let outcome = await model.refresh()

        guard case .updated = outcome else { Issue.record("got \(String(describing: outcome))"); return }
        #expect(model.data?.generated == CompatDate.instant("2026-10-20T03:17:00Z"))
        #expect(try Data(contentsOf: client.cacheFile) == newer)
        #expect(!model.isOffline)
    }

    @Test("The file is fetched at most once a day, and a failed connection does not count")
    func onceADay() async throws {
        let work = try scratchDirectory("compat-daily")
        defer { try? FileManager.default.removeItem(at: work) }
        let packed = try CompatFixture.packed()
        let server = Server([Self.offline, .success((packed, 200)), .success((packed, 404))])
        let client = client(work, server)
        let schema = try CompatSchema.bundled()
        let start = CompatFixture.generated

        guard case .offline = await client.refresh(now: start, schema: schema) else { Issue.record("1"); return }
        guard case .updated = await client.refresh(now: start.addingTimeInterval(60), schema: schema) else { Issue.record("2"); return }
        guard case .skipped = await client.refresh(now: start.addingTimeInterval(23 * 3600), schema: schema) else { Issue.record("3"); return }
        #expect(server.asked == 2)
        guard case .unavailable(404) = await client.refresh(now: start.addingTimeInterval(25 * 3600), schema: schema) else { Issue.record("4"); return }
        #expect(server.asked == 3)
        #expect(client.cached(schema: schema)?.generated == start)
    }

    @Test("A damaged cache file is ignored")
    func damagedCache() throws {
        let work = try scratchDirectory("compat-damaged")
        defer { try? FileManager.default.removeItem(at: work) }
        let client = client(work, Server([]))
        try FileManager.default.createDirectory(at: client.directory, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: client.cacheFile)
        #expect(client.cached(schema: try .bundled()) == nil)
    }
}

@Suite("Compatibility schema")
struct CompatSchemaTests {

    private func errors(_ change: (inout String) -> Void) throws -> [String] {
        var json = try CompatFixture.json()
        change(&json)
        let tree = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        return try CompatSchema.bundled().errors(tree)
    }

    @Test("The fixture has no errors")
    func fixtureIsValid() throws {
        #expect(try errors { _ in } == [])
    }

    @Test("Breaks are caught", arguments: [
        ("\"schema_version\":1", "\"schema_version\":true"),
        ("\"schema_version\":1", "\"schema_version\":2"),
        ("\"generated\":\"2026-10-19T03:17:00Z\"", "\"generated\":\"2026-10-19\""),
        ("\"status\":\"fresh\"", "\"status\":\"down\""),
        ("\"reports\":149", "\"reports\":0"),
        ("\"reports\":149", "\"reports\":\"149\""),
        ("\"since\":\"2025-10-01\"", "\"since\":\"2025-02-30\""),
        ("\"M4 Pro\":3.5", "\"Intel\":3.5"),
        ("\"crossover\":\"playable\"", "\"crossover\":\"great\""),
        ("\"sources\":{", "\"sources\":{\"macgamingdb\":{},"),
        ("\"anticheats\":[\"VAC\"]", "\"anticheats\":[]"),
        ("\"records\":{", "\"records\":{\"01\":{\"name\":\"x\",\"protondb\":{}},"),
        ("\"name\":\"Elden Ring\",", "\"name\":\"Elden Ring\",\"extra\":1,"),
    ])
    func breaksAreCaught(from: String, to: String) throws {
        let json = try CompatFixture.json()
        #expect(json.contains(from), "the fixture no longer contains \(from)")
        #expect(try !errors { $0 = $0.replacingOccurrences(of: from, with: to) }.isEmpty)
    }

    @Test("A keyword the validator does not know is refused")
    func unknownKeyword() {
        #expect(throws: CompatSchema.Unsupported.self) {
            try CompatSchema(Data(#"{"type":"string","maxLength":3}"#.utf8))
        }
    }

    @Test("Gzip checks its checksum")
    func gzipChecksum() throws {
        var packed = try CompatFixture.packed()
        #expect(try Gzip.decompress(packed).first == UInt8(ascii: "{"))
        packed[packed.count - 6] ^= 0xff
        #expect(throws: Gzip.Damaged.self) { try Gzip.decompress(packed) }
        #expect(throws: Gzip.Damaged.self) { try Gzip.decompress(Data("plain".utf8)) }
        #expect(Gzip.crc32(Data("123456789".utf8)) == 0xCBF4_3926)
    }
}
