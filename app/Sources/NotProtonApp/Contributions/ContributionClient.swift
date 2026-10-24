// The Cartouche community API (backend/README.md). Only this site receives contributions; nothing goes to MacGamingDB.

import Foundation
import RetroArchKit
import Security

enum CommunityService {

    static let urlKey = "community.apiURL"
    static let disabledKey = "community.disabled"
    static let infoKey = "CartoucheCommunityURL"

    // Unset until the production API is verified: then the Info.plist key, or a tester's defaults value
    static func baseURL(defaults: UserDefaults = .standard, bundle: Bundle = .main) -> URL? {
        guard !defaults.bool(forKey: disabledKey) else { return nil }
        let raw = defaults.string(forKey: urlKey) ?? (bundle.object(forInfoDictionaryKey: infoKey) as? String)
        guard let raw, let url = URL(string: raw), url.scheme == "https" || isLocal(url), url.host() != nil else { return nil }
        return QAEnvironment.url(url)
    }

    static func isLocal(_ url: URL) -> Bool {
        url.scheme == "http" && ["localhost", "127.0.0.1"].contains(url.host() ?? "")
    }
}

struct ContributionClient: Sendable {

    typealias Transport = @Sendable (URLRequest) async throws -> (Data, Int, [String: String])

    enum Failure: Error, Equatable, Sendable {
        case offline
        case retry(after: TimeInterval?)
        case unauthorized
        case conflict(String)
        case notFound(String)
        case rejected(String)
    }

    let base: URL
    var transport: Transport = ContributionClient.live
    // The same host pause as HTTPFetch: a 429 or 503 leaves the site alone until its Retry-After is over
    var cooldown: HTTPCooldown = .shared

    static let live: Transport = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        var headers: [String: String] = [:]
        for (key, value) in http?.allHeaderFields ?? [:] {
            if let key = key as? String, let value = value as? String { headers[key.lowercased()] = value }
        }
        return (data, http?.statusCode ?? 0, headers)
    }

    func url(_ path: String) -> URL { base.appending(path: "api/v1" + path) }

    func request(_ method: String, _ path: String, token: String? = nil, headers: [String: String] = [:],
                 body: Data? = nil) async throws(Failure) -> Data {
        var request = URLRequest(url: url(path), timeoutInterval: 30)
        request.httpMethod = method
        request.setValue("Cartouche/\(AppVersion.bundled)", forHTTPHeaderField: "User-Agent")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        if await cooldown.isPaused(request.url!) { throw .retry(after: nil) }
        let data: Data, status: Int, answer: [String: String]
        do {
            (data, status, answer) = try await transport(request)
        } catch {
            throw .offline
        }
        let pause = await cooldown.note(request.url!, status: status, retryAfter: answer["retry-after"])
        if (200...299).contains(status) { return data }
        let code = (try? JSONDecoder().decode(Problem.self, from: data))?.error.code ?? "http_\(status)"
        switch status {
        case 401: throw .unauthorized
        case 404: throw .notFound(code)
        case 409, 428: throw .conflict(code)
        case 429, 503: throw .retry(after: pause)
        case 400...499: throw .rejected(code)
        default: throw .retry(after: nil)
        }
    }

    private struct Problem: Decodable {
        struct Body: Decodable { let code: String }
        let error: Body
    }

    // MARK: Routes

    struct Credential: Codable, Equatable, Sendable {
        var contributorID: String
        var token: String

        enum CodingKeys: String, CodingKey { case contributorID = "contributor_id", token }
    }

    struct Accepted: Decodable, Equatable, Sendable {
        var id: String
        var status: String
        var version: Int?
        var revision: Int?
    }

    func createContributor() async throws(Failure) -> Credential {
        let data = try await request("POST", "/contributors")
        guard let credential = try? JSONDecoder().decode(Credential.self, from: data) else { throw .retry(after: nil) }
        return credential
    }

    func decode<T: Decodable>(_ data: Data) throws(Failure) -> T {
        do { return try JSONDecoder().decode(T.self, from: data) } catch { throw .rejected("unreadable_answer") }
    }

    func submitReport(game: String, body: Data, key: String, token: String) async throws(Failure) -> Accepted {
        try decode(try await request("POST", "/games/\(Self.segment(game))/reports", token: token,
                                     headers: ["Idempotency-Key": key], body: body))
    }

    func reviseReport(id: String, version: Int, body: Data, token: String) async throws(Failure) -> Accepted {
        try decode(try await request("PATCH", "/reports/\(Self.segment(id))", token: token,
                                     headers: ["If-Match": String(version)], body: body))
    }

    func withdrawReport(id: String, version: Int, token: String) async throws(Failure) -> Accepted {
        try decode(try await request("DELETE", "/reports/\(Self.segment(id))", token: token,
                                     headers: ["If-Match": String(version)]))
    }

    func proposeFix(game: String, body: Data, key: String, token: String) async throws(Failure) -> Accepted {
        try decode(try await request("POST", "/games/\(Self.segment(game))/fix-proposals", token: token,
                                     headers: ["Idempotency-Key": key], body: body))
    }

    func reviseFix(id: String, game: String, recipe: Data, key: String, token: String) async throws(Failure) -> Accepted {
        var body = Data("{\"game\":".utf8)
        body += (try? JSONEncoder().encode(game)) ?? Data()
        body += Data(",\"recipe\":".utf8) + recipe + Data("}".utf8)
        return try decode(try await request("POST", "/fixes/\(Self.segment(id))/revisions", token: token,
                                            headers: ["Idempotency-Key": key], body: body))
    }

    func withdrawFix(id: String, revision: Int, token: String) async throws(Failure) -> Accepted {
        try decode(try await request("DELETE", "/fixes/\(Self.segment(id))/revisions/\(revision)", token: token))
    }

    func proposeGame(_ game: ContributionGame, token: String) async throws(Failure) {
        let body = try? JSONEncoder().encode(["store": game.store, "store_id": game.storeID, "title": game.title])
        _ = try await request("POST", "/game-proposals", token: token, body: body)
    }

    struct OwnReport: Decodable, Equatable, Sendable {
        var id: String
        var gameID: String
        var status: String
        var version: Int
        var moderationReason: String?
        var payload: JSONValue?

        enum CodingKeys: String, CodingKey {
            case id, gameID = "game_id", status, version, moderationReason = "moderation_reason", payload
        }
    }

    struct OwnFix: Decodable, Equatable, Sendable {
        struct Revision: Decodable, Equatable, Sendable {
            var revision: Int
            var status: String
            var title: String?
            var moderationReason: String?

            enum CodingKeys: String, CodingKey {
                case revision, status, title, moderationReason = "moderation_reason"
            }
        }

        var id: String
        var gameID: String
        var revisions: [Revision]

        enum CodingKeys: String, CodingKey { case id, gameID = "game_id", revisions }
    }

    private struct Page<T: Decodable>: Decodable {
        var items: [T]
        var next: String?
    }

    func ownReports(token: String) async throws(Failure) -> [OwnReport] {
        struct Answer: Decodable {
            var reports: [OwnReport]
            var next_cursor: String?
        }
        var out: [OwnReport] = [], cursor: String?
        repeat {
            let answer: Answer = try decode(try await request("GET", "/me/reports?limit=100" + Self.cursor(cursor), token: token))
            out += answer.reports
            cursor = answer.next_cursor
        } while cursor != nil && out.count < 2000
        return out
    }

    func ownFixes(token: String) async throws(Failure) -> [OwnFix] {
        struct Answer: Decodable {
            var fixes: [OwnFix]
            var next_cursor: String?
        }
        var out: [OwnFix] = [], cursor: String?
        repeat {
            let answer: Answer = try decode(try await request("GET", "/me/fixes?limit=100" + Self.cursor(cursor), token: token))
            out += answer.fixes
            cursor = answer.next_cursor
        } while cursor != nil && out.count < 2000
        return out
    }

    func fixRegistry() async throws(Failure) -> Data { try await request("GET", "/fix-registry") }

    func fixArtifact(id: String, revision: Int) async throws(Failure) -> Data {
        try await request("GET", "/fixes/\(Self.segment(id))/revisions/\(revision)")
    }

    func appFeed() async throws(Failure) -> Data { try await request("GET", "/app-feed") }

    private static func cursor(_ value: String?) -> String {
        value.map { "&cursor=" + ($0.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "") } ?? ""
    }

    static func segment(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: ":-_."))) ?? value
    }
}

// The pseudonymous contributor secret: created on the first share, kept in the Keychain, never tied to an account or the Mac
protocol ContributorStore: Sendable {
    func read() throws -> ContributionClient.Credential?
    func write(_ credential: ContributionClient.Credential) throws
    func delete() throws
}

struct KeychainContributorStore: ContributorStore {
    var service = QAEnvironment.isActive ? "dev.bryann2k.cartouche.community.qa" : "dev.bryann2k.cartouche.community"
    var account: String

    init(base: URL) { account = base.host() ?? base.absoluteString }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    func read() throws -> ContributionClient.Credential? {
        guard let data = try Keychain.read(query) else { return nil }
        return try JSONDecoder().decode(ContributionClient.Credential.self, from: data)
    }

    func write(_ credential: ContributionClient.Credential) throws {
        let data = try JSONEncoder().encode(credential)
        try Keychain.write(data, matching: query, attributes: [
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrLabel as String: "Cartouche contributions",
        ])
    }

    func delete() throws { try Keychain.delete(query) }
}

actor ContributorIdentity {

    enum Problem: Error, Equatable, Sendable {
        case keychainUnreadable
        case waiting(until: Date)
        case client(ContributionClient.Failure)
    }

    let store: any ContributorStore
    private var cached: ContributionClient.Credential?
    private var createdUnsaved = false
    private var nextCreation: Date = .distantPast
    private var replacedAfterRefusal = false

    // A credential the Keychain could not keep still works until the app quits
    var isUnsaved: Bool { createdUnsaved }

    init(store: any ContributorStore) { self.store = store }

    func credential(client: ContributionClient, now: Date = Date()) async throws(Problem) -> ContributionClient.Credential {
        if let cached { return cached }
        let stored: ContributionClient.Credential?
        do { stored = try store.read() } catch { throw .keychainUnreadable }
        if let stored {
            cached = stored
            return stored
        }
        guard now >= nextCreation else { throw .waiting(until: nextCreation) }
        // One creation attempt per back-off window, whatever the cause of the failure
        nextCreation = now.addingTimeInterval(15 * 60)
        let created: ContributionClient.Credential
        do { created = try await client.createContributor() } catch { throw .client(error) }
        cached = created
        do { try store.write(created) } catch { createdUnsaved = true }
        return created
    }

    // The server no longer accepts this secret: one replacement per launch, never a loop
    func refused(_ credential: ContributionClient.Credential) -> Bool {
        guard !replacedAfterRefusal, cached == credential else { return false }
        replacedAfterRefusal = true
        cached = nil
        try? store.delete()
        nextCreation = .distantPast
        return true
    }
}
