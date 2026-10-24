// Steam's public store search, the fallback when the compatibility data cannot
// name a Windows installer game. The game's name is sent to Valve; the lookup
// runs only where the online-lookups choice (PrivacyChoices.fetchMacReports)
// allows it. Answers are cached in the support folder so a name is asked once.

import Foundation
import InstallerKit

struct SteamLookup: Sendable {

    struct Item: Codable, Sendable, Equatable {
        let appID: Int
        let name: String
        // Steam's "type": app, dlc, music, video, hardware, bundle
        let kind: String
        let capsule: URL?

        // Only real games are ever picked or offered: DLCs and soundtracks are not apps
        var isApp: Bool { kind == "app" }
    }

    typealias Fetch = HTTPFetch.Fetch

    var directory: URL = SupportPaths.support.appending(path: "compatibility/steam-lookup")
    var fetch: Fetch = HTTPFetch.download(timeout: 15, userAgent: MacGamingDBClient.userAgent)
    var now: @Sendable () -> Date = { Date() }

    static var standard: SteamLookup { SteamLookup() }

    // https://store.steampowered.com/api/storesearch/?term=<name>&l=english&cc=US — no key
    static func searchURL(term: String) -> URL? {
        let base = URL(string: "https://store.steampowered.com/api/storesearch/").map(QAEnvironment.url)
        var parts = base.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        parts?.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "l", value: "english"),
            URLQueryItem(name: "cc", value: "US"),
        ]
        return parts?.url
    }

    private struct Answer: Decodable {
        struct Entry: Decodable {
            let id: Int
            let name: String?
            let type: String?
            let tiny_image: String?
        }
        let items: [Entry]?
    }

    // One /api/storesearch answer. Items without an id or a name are dropped.
    static func items(in data: Data) -> [Item] {
        guard let answer = try? JSONDecoder().decode(Answer.self, from: data) else { return [] }
        return (answer.items ?? []).compactMap { entry in
            guard let name = entry.name, !name.isEmpty else { return nil }
            return Item(appID: entry.id, name: name, kind: entry.type ?? "",
                        capsule: entry.tiny_image.flatMap(URL.init(string:)))
        }
    }

    // The name normalization the title index uses: its tokens, minus trailing
    // edition words ("Deluxe Edition", "GOTY"), on both sides of the comparison.
    static func core(_ name: String) -> [String] {
        var tokens = GameIndex.tokens(name)
        while tokens.count > 1, let last = tokens.last, GameIndex.isNoise(last) { tokens.removeLast() }
        return tokens
    }

    // A confident match only: the exact normalized name (lowest app ID, like the
    // index's re-release rule), or a single result that extends the name.
    static func pick(_ term: String, in items: [Item]) -> Item? {
        let query = core(term)
        guard !query.isEmpty else { return nil }
        let apps = items.filter(\.isApp).map { ($0, core($0.name)) }.filter { !$0.1.isEmpty }
        if let exact = apps.filter({ $0.1 == query }).map(\.0).sorted(by: { $0.appID < $1.appID }).first {
            return exact
        }
        let longer = apps.filter { $0.1.count > query.count && Array($0.1.prefix(query.count)) == query }.map(\.0)
        return longer.count == 1 ? longer[0] : nil
    }

    // MARK: Lookup, cached

    struct Cached: Codable, Equatable {
        var fetched: Date
        var appID: Int?
        // The matched name, so the sheet can say "Identified as …" from a cache hit
        var name: String?
        // The request could not even reach Steam: kept briefly so a dead
        // connection is not retried on every cover
        var failed = false
    }

    static let foundTTL: TimeInterval = 30 * 86400
    static let missTTL: TimeInterval = 86400
    static let failedTTL: TimeInterval = 3600

    private func file(_ name: String) -> URL {
        directory.appending(path: Self.core(name).joined(separator: " ") + ".json")
    }

    private func load(_ name: String) -> Cached? {
        guard let data = try? Data(contentsOf: file(name)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Cached.self, from: data)
    }

    private func save(_ cached: Cached, _ name: String) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(cached) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? atomicReplace(file(name), with: data, step: "Steam lookup")
    }

    private func fresh(_ cached: Cached) -> Bool {
        let ttl = cached.failed ? Self.failedTTL : (cached.appID != nil ? Self.foundTTL : Self.missTTL)
        let now = now()
        return now >= cached.fetched && now.timeIntervalSince(cached.fetched) < ttl
    }

    // The Steam result for a game name, or nil: no match, no answer, or nothing
    // Steam knows. A decided "no match" is remembered for a day, a found ID for
    // a month, an unreachable Steam for an hour.
    func match(for name: String) async -> Item? {
        guard !Self.core(name).isEmpty else { return nil }
        let saved = load(name)
        if let saved, fresh(saved) {
            guard let appID = saved.appID else { return nil }
            return Item(appID: appID, name: saved.name ?? name, kind: "app", capsule: nil)
        }
        guard let url = Self.searchURL(term: name),
              let (data, status) = try? await fetch(url), status == 200
        else {
            // The outage is remembered briefly; a stale answer, if any, still serves.
            save(Cached(fetched: now(), appID: saved?.appID, name: saved?.name, failed: true), name)
            guard let appID = saved?.appID else { return nil }
            return Item(appID: appID, name: saved?.name ?? name, kind: "app", capsule: nil)
        }
        let found = Self.pick(name, in: Self.items(in: data))
        save(Cached(fetched: now(), appID: found?.appID, name: found?.name), name)
        return found
    }

    // The results themselves, for the Change Cover sheet; not cached
    func search(_ term: String) async -> [Item] {
        guard let url = Self.searchURL(term: term),
              let (data, status) = try? await fetch(url), status == 200
        else { return [] }
        return Self.items(in: data)
    }
}
