
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
    func refresh() async -> CompatibilityClient.Outcome? {
        guard let schema else {
            AppLog.note("compatibility schema missing from the app bundle")
            return nil
        }
        if data == nil { await load() }
        guard dailyChecks() else { return .skipped }
        await refreshCommunity()
        let outcome = await client.refresh(now: now(), schema: schema)
        switch outcome {
        case .updated(let fresh):
            data = fresh
            isOffline = false
            serverBusy = false
        case .offline:
            isOffline = true
        case .unavailable(let status) where HTTPBackoff.throttles(status):
            isOffline = false
            serverBusy = true
        case .skipped, .unavailable, .rejected:
            isOffline = false
        }
        return outcome
    }

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

    var ageNotice: String? {
        guard let generated = data?.generated else { return nil }
        return CompatibilityAge.notice(generated: generated, now: now(), offline: isOffline)
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
            : String(localized: "Compatibility data from \(n) days ago.")
    }
}
