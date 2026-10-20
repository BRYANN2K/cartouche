
import Foundation
import Observation

@MainActor
@Observable
final class CompatibilityModel {

    private(set) var data: CompatData?
    private(set) var isOffline = false
    private(set) var macReports: [Int: MacGamingDBEntry] = [:]

    @ObservationIgnored let client: CompatibilityClient
    @ObservationIgnored let schema: CompatSchema?
    @ObservationIgnored let macGamingDB: MacGamingDBClient
    @ObservationIgnored let choices: PrivacyChoices
    @ObservationIgnored var now: @Sendable () -> Date = { Date() }
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
    }

    @discardableResult
    func refresh() async -> CompatibilityClient.Outcome? {
        guard let schema else {
            AppLog.note("compatibility schema missing from the app bundle")
            return nil
        }
        if data == nil { await load() }
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
