// The site's app feed (backend/src/app-feed.ts), cached apart from compat.json.gz. Its declarations are already
// resolved by the site's shared policy, so the app reads them instead of interpreting the sources again.

import Foundation

struct CommunityFeed: Decodable, Sendable, Equatable {

    struct ModeException: Decodable, Sendable, Equatable {
        let mode: String
        let status: String
        let notes: String?
    }

    struct Declaration: Decodable, Sendable, Equatable {
        let method: String?
        let label: String
        let tone: String?
        let source: String?
        let sourceURLs: [String]?
        let checkedAt: String?
        let protectedOnline: String?
        let modeExceptions: [ModeException]?
        let notes: String?

        enum CodingKeys: String, CodingKey {
            case method, label, tone, source, sourceURLs = "source_urls", checkedAt = "checked_at",
                 protectedOnline = "protected_online", modeExceptions = "mode_exceptions", notes
        }
    }

    struct AntiCheat: Decodable, Sendable, Equatable {
        enum State: String, Decodable, Sendable { case present, absent, unknown }
        let state: State
        let names: [String]
        let sources: [String]
    }

    struct Cohort: Decodable, Sendable, Equatable {
        struct Configuration: Decodable, Sendable, Equatable {
            let method: PlayMethod
            let runner: String?
            let backend: String?
            let mac: ContributionWire.Mac?
        }

        let configuration: Configuration
        let measurementMethod: String?
        let anticheatMode: String?
        let contributors: Int
        let sessions: Int
        let medianFPS: Double?
        let outcomes: [String: Int]
        let anticheatResults: [String: Int]
        let conflicting: Bool
        let confidence: String
        let lastTestedAt: String
        let expiresAt: String

        enum CodingKeys: String, CodingKey {
            case configuration, measurementMethod = "measurement_method", anticheatMode = "anticheat_mode", contributors,
                 sessions, medianFPS = "median_fps", outcomes, anticheatResults = "anticheat_results", conflicting,
                 confidence, lastTestedAt = "last_tested_at", expiresAt = "expires_at"
        }
    }

    struct FixRef: Decodable, Sendable, Equatable, Hashable {
        let id: String
        let revision: Int
    }

    struct Store: Decodable, Sendable, Equatable {
        let store: String
        let storeID: String

        enum CodingKeys: String, CodingKey { case store, storeID = "store_id" }
    }

    struct Declarations: Decodable, Sendable, Equatable {
        let native: Declaration?
        let wine: Declaration?
    }

    struct GameEntry: Decodable, Sendable, Equatable {
        let id: String
        let title: String
        let stores: [Store]
        let declarations: Declarations
        let anticheat: AntiCheat
        let cohorts: [Cohort]
        let fixes: [FixRef]
        let revokedFixes: [FixRef]

        enum CodingKeys: String, CodingKey {
            case id, title, stores, declarations, anticheat, cohorts, fixes, revokedFixes = "revoked_fixes"
        }
    }

    let generatedAt: Date
    let refreshAfter: Date
    let usableUntil: Date
    let games: [GameEntry]
    let byStore: [String: Int]

    struct Rejected: Error, CustomStringConvertible {
        let description: String
    }

    enum CodingKeys: String, CodingKey {
        case schema, schemaVersion = "schema_version", generatedAt = "generated_at", refreshAfter = "refresh_after",
             usableUntil = "usable_until", games
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // A newer or different format is refused whole, so the last valid copy stays in use
        guard try c.decode(String.self, forKey: .schema) == "cartouche-app-feed",
              try c.decode(Int.self, forKey: .schemaVersion) == 1
        else { throw Rejected(description: "unknown feed format") }
        func date(_ key: CodingKeys) throws -> Date {
            let text = try c.decode(String.self, forKey: key)
            guard let d = ContributionAdapter.date(text) else {
                throw DecodingError.dataCorruptedError(forKey: key, in: c, debugDescription: text)
            }
            return d
        }
        generatedAt = try date(.generatedAt)
        refreshAfter = try date(.refreshAfter)
        usableUntil = try date(.usableUntil)
        games = try c.decode([GameEntry].self, forKey: .games)
        var index: [String: Int] = [:]
        for (i, game) in games.enumerated() {
            for store in game.stores { index["\(store.store):\(store.storeID)"] = i }
        }
        byStore = index
    }

    static func read(_ data: Data) throws -> CommunityFeed {
        try JSONDecoder().decode(CommunityFeed.self, from: data)
    }

    func game(_ ref: String) -> GameEntry? { byStore[ref].map { games[$0] } }

    static func == (a: CommunityFeed, b: CommunityFeed) -> Bool {
        a.generatedAt == b.generatedAt && a.games == b.games
    }
}

struct CommunityFeedClient: Sendable {

    enum Outcome: Equatable, Sendable {
        case skipped
        case updated
        case offline
        case busy
        case rejected(String)
    }

    let directory: URL
    var fetch: @Sendable () async throws -> Data

    var cacheFile: URL { directory.appending(path: "app-feed.json") }
    var stateFile: URL { directory.appending(path: "app-feed-state.json") }

    static func standard(client: ContributionClient) -> CommunityFeedClient {
        CommunityFeedClient(directory: SupportPaths.support.appending(path: "community")) {
            do { return try await client.appFeed() } catch { throw error }
        }
    }

    func cached() -> CommunityFeed? {
        guard let data = try? Data(contentsOf: cacheFile) else { return nil }
        return try? CommunityFeed.read(data)
    }

    private struct State: Codable { var lastAttempt: Date }

    private func lastAttempt() -> Date? {
        guard let data = try? Data(contentsOf: stateFile) else { return nil }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return (try? d.decode(State.self, from: data))?.lastAttempt
    }

    private func record(_ now: Date) {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        guard let data = try? e.encode(State(lastAttempt: now)) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? atomicReplace(stateFile, with: data, step: "community feed")
    }

    // At most one attempt an hour, and none while the copy in use is before its refresh time
    func refresh(now: Date, current: CommunityFeed?) async -> (Outcome, CommunityFeed?) {
        if let current, now < current.refreshAfter { return (.skipped, nil) }
        if let last = lastAttempt(), now.timeIntervalSince(last) < 3600, now >= last { return (.skipped, nil) }
        record(now)
        let body: Data
        do {
            body = try await fetch()
        } catch ContributionClient.Failure.retry {
            return (.busy, nil)
        } catch {
            return (.offline, nil)
        }
        let fresh: CommunityFeed
        do { fresh = try CommunityFeed.read(body) } catch { return (.rejected("\(error)"), nil) }
        if let current, fresh.generatedAt < current.generatedAt { return (.rejected("older than the copy in use"), nil) }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? atomicReplace(cacheFile, with: body, step: "community feed")
        return (.updated, fresh)
    }
}
