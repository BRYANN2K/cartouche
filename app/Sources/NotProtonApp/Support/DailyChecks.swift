// Settings > General's "Check for updates and compatibility data daily". Off,
// Sparkle's automatic check, the compatibility file and the runner manifest all
// wait; the menu's Check for Updates still works.

import Foundation

enum DailyChecks {
    static let key = "dailyUpdateChecks"

    static func enabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }
}
