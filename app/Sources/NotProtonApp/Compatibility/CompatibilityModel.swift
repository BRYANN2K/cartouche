
import Foundation
import Observation

@MainActor
@Observable
final class CompatibilityModel {

    private(set) var data: CompatData?
    private(set) var isOffline = false
    private(set) var macReports: [Int: MacGamingDBEntry] = [:]
    private(set) var community: CommunityFeed?
    // A source answered 429 or 503: its last copy stays in use and the panel says why it is not refreshed
    private(set) var serverBusy = false
    // The last check that reached for the file failed; until one succeeds, stale data gets a notice with Retry
    private(set) var refreshFailed = false
    private(set) var isRefreshing = false

    @ObservationIgnored let client: CompatibilityClient
    @ObservationIgnored let schema: CompatSchema?
    @ObservationIgnored let macGamingDB: MacGamingDBClient
    @ObservationIgnored let choices: PrivacyChoices
    @ObservationIgnored let feedClient: CommunityFeedClient?
    @ObservationIgnored var now: @Sendable () -> Date = { Date() }
    @ObservationIgnored var dailyChecks: () -> Bool = { DailyChecks.enabled() }
    @ObservationIgnored var chip: String? = MacChip.current()

    init(
        client: CompatibilityClient = .standard, schema: CompatSchema? = try? .bundled(),
        macGamingDB: MacGamingDBClient = .standard, choices: PrivacyChoices = PrivacyChoices(),
        feedClient: CommunityFeedClient? = CommunityService.baseURL().map { .standard(client: ContributionClient(base: $0)) }
    ) {
        self.feedClient = feedClient
        self.client = client
        self.schema = schema
        self.macGamingDB = macGamingDB
        self.choices = choices
    }

    func openGame(appID: Int) async {
        guard choices.fetchMacReports else { return }
        if let entry = await macGamingDB.reports(appID: appID, now: now()) {
            macReports[appID] = entry
        }
    }

    // Unpacking and validating run off the main actor; only the write stays here.
    func load() async {
        guard let schema else { return }
        let client = client
        data = await Task.detached { client.cached(schema: schema) }.value
        if let feedClient, community == nil { community = await Task.detached { feedClient.cached() }.value }
    }

    @discardableResult
    func refresh(force: Bool = false) async -> CompatibilityClient.Outcome? {
        guard let schema else {
            AppLog.note("compatibility schema missing from the app bundle")
            return nil
        }
        if data == nil { await load() }
        guard force || dailyChecks() else { return .skipped }
        isRefreshing = true
        defer { isRefreshing = false }
        await refreshCommunity()
        let outcome = await client.refresh(now: now(), schema: schema, force: force)
        switch outcome {
        case .updated(let fresh):
            data = fresh
            isOffline = false
            serverBusy = false
            refreshFailed = false
        case .offline:
            isOffline = true
            refreshFailed = true
        case .unavailable(let status) where HTTPBackoff.throttles(status):
            isOffline = false
            serverBusy = true
            refreshFailed = true
        case .unavailable, .rejected:
            isOffline = false
            refreshFailed = true
        case .skipped:
            break
        }
        return outcome
    }

    func retry() async {
        guard !isRefreshing else { return }
        await refresh(force: true)
    }

    static let checkInterval: TimeInterval = 6 * 3600

    // While the app stays open: a check every few hours, which the client turns into one download a day, and
    // after a failure a sooner retry that doubles up to the normal interval
    func keepFresh(sleep: @escaping (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) async {
        let backoff = HTTPBackoff(base: 15 * 60, cap: Self.checkInterval)
        var failures = refreshFailed ? 1 : 0
        while !Task.isCancelled {
            do { try await sleep(failures == 0 ? Self.checkInterval : backoff.delay(attempt: failures)) } catch { return }
            await refresh()
            failures = refreshFailed ? failures + 1 : 0
        }
    }

    var gpuStrength: [String: Double] { MacGPUProfiles.current(data?.gpuStrength) }

    func record(appID: Int) -> CompatRecord? { data?.record(appID: appID) }

    // Reading the site's feed follows the same choice as fetching Mac reports; a failure keeps the last valid copy
    func refreshCommunity() async {
        guard let feedClient, choices.fetchMacReports else { return }
        let (outcome, fresh) = await feedClient.refresh(now: now(), current: community)
        if let fresh { community = fresh }
        if outcome == .busy { serverBusy = true } else if outcome == .updated { serverBusy = false }
    }

    func resolved(_ game: Game, method: PlayMethod) -> ResolvedCompatibility {
        let ref: String? = switch ContributionGame.resolve(game) {
        case .exact(let g), .needsConfirmation(let g): g.ref
        case .unknown: nil
        }
        let legacy = (game.steamAppID ?? game.compatAppID).flatMap { record(appID: $0) }
        return ResolvedCompatibility.resolve(feed: community, ref: ref, method: method, legacy: legacy, now: now())
    }

    var busyNotice: String? {
        serverBusy ? String(localized: "The compatibility server is busy. Cartouche shows its last copy and will try again later.") : nil
    }

    // Old data alone says nothing: the file is rebuilt upstream and may simply not have changed
    var ageNotice: String? {
        guard refreshFailed, let generated = data?.generated,
              let notice = CompatibilityAge.notice(generated: generated, now: now(), offline: isOffline)
        else { return nil }
        return busyNotice ?? notice
    }
}

enum CompatibilityAge {

    static let shownAfterDays = 3

    static func days(from generated: Date, to now: Date) -> Int {
        max(0, Int((now.timeIntervalSince(generated) / 86400).rounded(.down)))
    }

    static func notice(generated: Date, now: Date, offline: Bool) -> String? {
        let n = days(from: generated, to: now)
        guard n > shownAfterDays else { return nil }
        return offline
            ? String(localized: "Offline. Compatibility data from \(n) days ago.")
            : String(localized: "Couldn't refresh. Compatibility data from \(n) days ago.")
    }
}
