// MacGamingDB publishes no data license, so Cartouche never redistributes its reports.
// The app asks for one game when that game's panel needs it, and keeps the answer on this Mac.

import Foundation

struct MacGamingDBEntry: Codable, Sendable, Equatable {
    let rating: CompatRating?
    let reviewCount: Int
    let topLayer: TranslationLayer?
    let reports: [MacReport]

    static let empty = MacGamingDBEntry(rating: nil, reviewCount: 0, topLayer: nil, reports: [])

    struct Unreadable: Error, CustomStringConvertible {
        let description: String
    }

    private struct Answer: Decodable {
        struct Game: Decodable {
            let aggregatedPerformance: String?
            let reviewCount: Int?
        }
        let game: Game
        let reviews: [Review]
    }

    private struct Review: Decodable {
        let chipset: String?
        let chipsetVariant: String?
        let playMethod: String?
        let translationLayer: String?
        let performance: String?
        let fps: Double?
        let graphicsSettings: String?
        let createdAt: String?
    }

    private static let ratings = ["UNPLAYABLE", "BARELY_PLAYABLE", "PLAYABLE", "GOOD", "VERY_GOOD", "EXCELLENT"]
    private static let methods: [String: PlayMethod] = ["NATIVE": .native, "CROSSOVER": .wine, "PARALLELS": .parallels, "OTHER": .other]
    private static let variants = ["BASE": "", "PRO": " Pro", "MAX": " Max", "ULTRA": " Ultra"]

    // One /api/rest/games/{appid} answer. A report with a value Cartouche does not know is left out.
    static func parse(_ data: Data) throws -> MacGamingDBEntry {
        let answer: Answer
        do {
            answer = try JSONDecoder().decode(Answer.self, from: data)
        } catch {
            throw Unreadable(description: "not a MacGamingDB game answer")
        }
        let rows = answer.reviews.compactMap(row)
        var counts: [TranslationLayer: Int] = [:]
        for layer in rows.compactMap(\.layer) { counts[layer, default: 0] += 1 }
        // Ties go to the first layer in this order
        let order: [TranslationLayer] = [.d3dmetal, .dxmt, .dxvk]
        let top = order.filter { counts[$0] != nil }.max { counts[$0]! < counts[$1]! }
        let rating = answer.game.aggregatedPerformance.flatMap(ratings.firstIndex(of:)).flatMap(CompatRating.init(score:))
        return MacGamingDBEntry(
            rating: rating, reviewCount: answer.game.reviewCount ?? answer.reviews.count, topLayer: top, reports: rows)
    }

    private static func row(_ r: Review) -> MacReport? {
        guard let chipset = r.chipset, chipset.wholeMatch(of: /M[1-9]|A[1-9][0-9]/) != nil,
              let suffix = variants[r.chipsetVariant ?? "BASE"],
              let method = r.playMethod.flatMap({ methods[$0] }),
              let score = r.performance.flatMap(ratings.firstIndex(of:)),
              let created = r.createdAt, created.prefixMatch(of: /\d{4}-\d{2}-\d{2}/) != nil
        else { return nil }
        let layer: TranslationLayer?
        switch r.translationLayer {
        case nil, "NONE": layer = nil
        case "D3D_METAL": layer = .d3dmetal
        case "DXMT": layer = .dxmt
        case "DXVK": layer = .dxvk
        default: return nil
        }
        let settings: GraphicsSettings?
        switch r.graphicsSettings {
        case nil: settings = nil
        case let s?:
            guard let known = GraphicsSettings(rawValue: s.lowercased()) else { return nil }
            settings = known
        }
        let fps = r.fps.flatMap { (1...1000).contains($0) ? Int($0.rounded()) : nil }
        return MacReport(chip: chipset + suffix, method: method, layer: layer, rating: score, fps: fps,
                         settings: settings, date: String(created.prefix(10)))
    }
}

struct MacReport: Codable, Sendable, Equatable {
    let chip: String
    let method: PlayMethod
    let layer: TranslationLayer?
    let rating: Int
    let fps: Int?
    let settings: GraphicsSettings?
    let date: String
}

// Fetches on demand only, never the whole library: one request per game per day,
// at most two at a time
actor MacGamingDBClient {

    static var api: URL { QAEnvironment.url(URL(string: "https://macgamingdb.app/api/rest/games/")!) }
    static let maxConcurrent = 2

    typealias Fetch = HTTPFetch.Fetch
    static let userAgent = "Cartouche/\(AppVersion.bundled) (+https://cartouche.bryann2k.dev)"

    let directory: URL
    private let fetch: Fetch
    private var inFlight: [Int: Task<MacGamingDBEntry?, Never>] = [:]
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(directory: URL, fetch: @escaping Fetch = HTTPFetch.download(
        timeout: 20, userAgent: MacGamingDBClient.userAgent)) {
        self.directory = directory
        self.fetch = fetch
    }

    static var standard: MacGamingDBClient {
        MacGamingDBClient(directory: SupportPaths.support.appending(path: "compatibility/macgamingdb"))
    }

    private struct Cached: Codable {
        let fetched: Date
        let entry: MacGamingDBEntry
    }

    private func file(_ appID: Int) -> URL { directory.appending(path: "\(appID).json") }

    func cached(appID: Int) -> MacGamingDBEntry? { load(appID)?.entry }

    private func load(_ appID: Int) -> Cached? {
        guard let data = try? Data(contentsOf: file(appID)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Cached.self, from: data)
    }

    // The cached copy when it is less than a day old, otherwise a fresh answer.
    // When MacGamingDB cannot answer, the last good copy is used.
    func reports(appID: Int, now: Date) async -> MacGamingDBEntry? {
        let saved = load(appID)
        if let saved, now >= saved.fetched, now.timeIntervalSince(saved.fetched) < 24 * 3600 {
            return saved.entry
        }
        if let task = inFlight[appID] { return await task.value }
        let task = Task { await self.ask(appID: appID, now: now, fallback: saved?.entry) }
        inFlight[appID] = task
        let entry = await task.value
        inFlight[appID] = nil
        return entry
    }

    private func ask(appID: Int, now: Date, fallback: MacGamingDBEntry?) async -> MacGamingDBEntry? {
        await acquire()
        defer { release() }
        let body: Data, status: Int
        do {
            (body, status) = try await fetch(Self.api.appending(path: String(appID)))
        } catch {
            return fallback
        }
        let entry: MacGamingDBEntry
        switch status {
        case 200:
            guard let parsed = try? MacGamingDBEntry.parse(body) else {
                AppLog.note("MacGamingDB answer for \(appID) unreadable, kept the previous copy")
                return fallback
            }
            entry = parsed
        case 404:
            entry = .empty
        default:
            return fallback
        }
        save(Cached(fetched: now, entry: entry), appID)
        return entry
    }

    private func save(_ cached: Cached, _ appID: Int) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(cached) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? atomicReplace(file(appID), with: data, step: "MacGamingDB")
    }

    private func acquire() async {
        if running < Self.maxConcurrent {
            running += 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    // A waiting request takes over the slot, so running stays the same
    private func release() {
        if waiting.isEmpty {
            running -= 1
        } else {
            waiting.removeFirst().resume()
        }
    }
}
