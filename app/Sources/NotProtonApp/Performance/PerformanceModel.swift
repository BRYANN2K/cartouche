// Your Play for the game panel (P8): reads finished sessions into the store, keeps
// each game's numbers, and shares new ones only when the user turned sharing on.

import Foundation
import Observation

@MainActor
@Observable
final class PerformanceModel {

    private(set) var plays: [Int: GamePlay] = [:]

    @ObservationIgnored let store: PerformanceStore
    @ObservationIgnored let sharing: PerformanceSharing
    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored var now: @Sendable () -> Date = { Date() }
    @ObservationIgnored private var refreshing = false

    init(store: PerformanceStore = PerformanceStore(), sharing: PerformanceSharing = PerformanceSharing(),
         defaults: UserDefaults = .standard) {
        self.store = store
        self.sharing = sharing
        self.defaults = defaults
    }

    func play(appID: Int?) -> GamePlay? { appID.flatMap { plays[$0] } }

    // Off the main thread: new folders into SQLite, then every game's numbers
    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let store = store, now = now()
        let (added, sessions) = await Task.detached {
            let added = (try? store.ingest(now: now)) ?? []
            return (added, (try? store.sessions()) ?? [])
        }.value
        plays = Dictionary(grouping: sessions, by: \.appID).compactMapValues(GamePlay.summarize)
        if !added.isEmpty {
            await sharing.share(added, enabled: defaults.bool(forKey: PrivacyChoices.sharePerformanceKey))
        }
    }
}
