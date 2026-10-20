
import Foundation
import Observation

@MainActor
@Observable
final class PrivacyChoices {

    static let macReportsKey = "privacy.fetchMacReports"
    static let sharePerformanceKey = "privacy.sharePerformance"

    @ObservationIgnored let defaults: UserDefaults

    var fetchMacReports: Bool {
        didSet { defaults.set(fetchMacReports, forKey: Self.macReportsKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        fetchMacReports = defaults.object(forKey: Self.macReportsKey) as? Bool ?? true
    }
}
