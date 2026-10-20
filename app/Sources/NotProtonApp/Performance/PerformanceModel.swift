// Shares new numbers only when the user turned sharing on.

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
    @ObservationIgnored private var hasLoaded = false

    init(store: PerformanceStore = PerformanceStore(), sharing: PerformanceSharing = PerformanceSharing(),
         defaults: UserDefaults = .standard) {
        self.store = store
        self.sharing = sharing
        self.defaults = defaults
    }

    func play(appID: Int?) -> GamePlay? { appID.flatMap { plays[$0] } }

    // Off the main thread; the full table is read once, later refreshes touch only the games a folder added.
    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let store = store, now = now()
        if !hasLoaded {
            let (added, sessions) = await Task.detached {
                ((try? store.ingest(now: now)) ?? [], (try? store.sessions()) ?? [])
            }.value
            hasLoaded = true
            plays = Dictionary(grouping: sessions, by: \.appID).compactMapValues(GamePlay.summarize)
            await share(added)
            return
        }
        let added = await Task.detached { (try? store.ingest(now: now)) ?? [] }.value
        for appID in Set(added.map(\.appID)) {
            let sessions = await Task.detached { (try? store.sessions(appID: appID)) ?? [] }.value
            plays[appID] = GamePlay.summarize(sessions)
        }
        await share(added)
    }

    func refreshIfNeeded() async {
        let store = store
        let pending = await Task.detached { store.hasIncomingSessions }.value
        if pending || !hasLoaded { await refresh() }
    }

    private func share(_ added: [StoredSession]) async {
        if !added.isEmpty {
            await sharing.share(added, enabled: defaults.bool(forKey: PrivacyChoices.sharePerformanceKey))
        }
    }
}
