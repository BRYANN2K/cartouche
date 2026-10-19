// What Cartouche may send to other services, set in Settings > Privacy

import Foundation
import Observation

@MainActor
@Observable
final class PrivacyChoices {

    static let macReportsKey = "privacy.fetchMacReports"
    static let sharePerformanceKey = "privacy.sharePerformance"

    @ObservationIgnored let defaults: UserDefaults

    // On by default. Off, nothing is sent to MacGamingDB and no estimate is shown.
    var fetchMacReports: Bool {
        didSet { defaults.set(fetchMacReports, forKey: Self.macReportsKey) }
    }

    // Off by default. On, each measured session's report is sent, see PerformanceSharing.
    var sharePerformance: Bool {
        didSet { defaults.set(sharePerformance, forKey: Self.sharePerformanceKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        fetchMacReports = defaults.object(forKey: Self.macReportsKey) as? Bool ?? true
        sharePerformance = defaults.object(forKey: Self.sharePerformanceKey) as? Bool ?? false
    }
}
