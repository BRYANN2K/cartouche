
import Foundation

enum DailyChecks {
    static let key = "dailyUpdateChecks"

    static func enabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }
}
