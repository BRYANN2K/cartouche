import Foundation

// The three access levels of Settings > Agents. Each tool belongs to one; a
// level sees every tool at or under it.
enum AgentLevel: String, Codable, Sendable, CaseIterable, Comparable {
    case readOnly, standard, full

    var rank: Int { Self.allCases.firstIndex(of: self)! }
    static func < (a: AgentLevel, b: AgentLevel) -> Bool { a.rank < b.rank }

    var title: String {
        switch self {
        case .readOnly: String(localized: "Read Only")
        case .standard: String(localized: "Standard")
        case .full: String(localized: "Full")
        }
    }
}

// What read tools may expose: app-owned folders plus the folders the user
// granted. Anything outside this list is refused, and the secret scan redacts
// it before it can leave the app.
struct AgentRoots: Sendable {
    var support: URL
    var logs: URL
    var installs: URL
    var retroarch: URL
    var caches: URL
    // Game folders the user added (console games), installer folders of
    // installed games, and Steam library prefixes.
    var granted: [URL] = []

    var allowed: [URL] { [support, logs, installs, retroarch, caches] + granted }
}
