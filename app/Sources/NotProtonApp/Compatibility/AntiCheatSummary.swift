// Anti-cheat as ProtonDB and AreWeAntiCheatYet report it for Linux. Cartouche has no
// Mac data on anti-cheat, so no line here may claim what happens on a Mac.

import Foundation

struct AntiCheatSummary: Equatable, Sendable {

    enum Level: Equatable, Sendable {
        case onlineWorks
        case onlineFails
        case untested
        case blocked
    }

    let level: Level
    let title: String
    let details: [String]

    // Nil when AreWeAntiCheatYet lists no anti-cheat for the game
    init?(record: CompatRecord?) {
        guard let entry = record?.areweanticheatyet else { return nil }
        let pdb = record?.protondb
        let names = ListFormatter.localizedString(byJoining: entry.anticheats)
        let blockedByStatus = entry.status == .denied || entry.status == .broken

        if pdb?.verdict == .doesntRun {
            level = .blocked
            title = String(localized: "Doesn’t run on Linux")
        } else if blockedByStatus {
            level = .blocked
            title = String(localized: "Anti-cheat blocks Linux")
        } else if let pdb, pdb.onlineTried > 0 {
            if pdb.onlinePlayed * 2 >= pdb.onlineTried {
                level = .onlineWorks
                title = String(localized: "Online works on Linux, \(pdb.onlinePlayed) of \(pdb.onlineTried) reports")
            } else {
                level = .onlineFails
                title = String(localized: "Online fails on Linux in \(pdb.onlineTried - pdb.onlinePlayed) of \(pdb.onlineTried) reports")
            }
        } else {
            level = .untested
            title = String(localized: "Online untested on Linux")
        }

        var details: [String] = []
        if let pdb {
            details.append(pdb.verdict == .doesntRun
                ? String(localized: "\(pdb.reports - pdb.works) of \(pdb.reports) recent ProtonDB reports say it doesn’t run on Linux.")
                : String(localized: "Runs on Linux in \(pdb.works) of \(pdb.reports) recent ProtonDB reports."))
            if pdb.onlineTried == 0 {
                details.append(String(localized: "No recent ProtonDB report tried online play on Linux."))
            }
        }
        details.append(Self.statusLine(entry.status, names))
        self.details = details
    }

    static func statusLine(_ status: AntiCheatEntry.Status, _ names: String) -> String {
        switch status {
        case .supported: String(localized: "AreWeAntiCheatYet lists \(names) as supported on Linux.")
        case .running: String(localized: "AreWeAntiCheatYet lists \(names) as running on Linux without official support.")
        case .planned: String(localized: "AreWeAntiCheatYet lists Linux support for \(names) as planned.")
        case .broken: String(localized: "AreWeAntiCheatYet lists \(names) as broken on Linux.")
        case .denied: String(localized: "AreWeAntiCheatYet lists \(names) as denied on Linux by the developer.")
        }
    }

    var lines: [String] { [title] + details }
}
