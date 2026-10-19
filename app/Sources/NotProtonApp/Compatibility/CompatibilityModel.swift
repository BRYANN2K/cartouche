// What the library and the game panel read: the compatibility data in use,
// whether the last fetch reached the server, and how old the data is.

import Foundation
import Observation

@MainActor
@Observable
final class CompatibilityModel {

    private(set) var data: CompatData?
    private(set) var isOffline = false
    // MacGamingDB answers for the games opened so far
    private(set) var macReports: [Int: MacGamingDBEntry] = [:]

    @ObservationIgnored let client: CompatibilityClient
    @ObservationIgnored let schema: CompatSchema?
    @ObservationIgnored let macGamingDB: MacGamingDBClient
    @ObservationIgnored let choices: PrivacyChoices
    @ObservationIgnored var now: @Sendable () -> Date = { Date() }
    // Settings > General's daily switch; tests drive it
    @ObservationIgnored var dailyChecks: () -> Bool = { DailyChecks.enabled() }
    @ObservationIgnored var chip: String? = MacChip.current()

    init(
        client: CompatibilityClient = .standard, schema: CompatSchema? = try? .bundled(),
        macGamingDB: MacGamingDBClient = .standard, choices: PrivacyChoices = PrivacyChoices()
    ) {
        self.client = client
        self.schema = schema
        self.macGamingDB = macGamingDB
        self.choices = choices
    }

    // Called when a game's panel or Details sheet opens. Never for the whole library.
    func openGame(appID: Int) async {
        guard choices.fetchMacReports else { return }
        if let entry = await macGamingDB.reports(appID: appID, now: now()) {
            macReports[appID] = entry
        }
    }

    // Reads the cached copy, so the library has data before any network answer
    func load() {
        guard let schema else { return }
        data = client.cached(schema: schema)
    }

    @discardableResult
    func refresh() async -> CompatibilityClient.Outcome? {
        guard let schema else {
            AppLog.note("compatibility schema missing from the app bundle")
            return nil
        }
        if data == nil { load() }
        // The daily switch keeps the cached copy in place and asks for nothing
        guard dailyChecks() else { return .skipped }
        let outcome = await client.refresh(now: now(), schema: schema)
        switch outcome {
        case .updated(let fresh):
            data = fresh
            isOffline = false
        case .offline:
            isOffline = true
        case .skipped, .unavailable, .rejected:
            isOffline = false
        }
        return outcome
    }

    func record(appID: Int) -> CompatRecord? { data?.record(appID: appID) }

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
