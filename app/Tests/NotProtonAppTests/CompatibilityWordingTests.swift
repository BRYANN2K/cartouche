import Foundation
import Testing

@testable import NotProtonApp

@Suite("Anti-cheat wording and attribution")
struct CompatibilityWordingTests {

    private func record(_ pdb: ProtonDBEntry?, _ status: AntiCheatEntry.Status, cheats: [String] = ["Easy Anti-Cheat"]) -> CompatRecord {
        CompatRecord(
            name: "Game", applegamingwiki: nil, protondb: pdb,
            areweanticheatyet: AntiCheatEntry(fetched: "2026-10-19", status: status, anticheats: cheats, native: false, changed: "2024-01-01"))
    }

    private func pdb(_ reports: Int, _ works: Int, _ tried: Int, _ played: Int, _ verdict: ProtonDBEntry.Verdict) -> ProtonDBEntry {
        ProtonDBEntry(fetched: "2026-10-01", since: "2025-10-01", reports: reports, works: works,
                      onlineTried: tried, onlinePlayed: played, verdict: verdict)
    }

    // Every combination the data can give
    private var everySummary: [AntiCheatSummary] {
        let protondb: [ProtonDBEntry?] = [
            nil, pdb(456, 402, 26, 26, .runs), pdb(100, 90, 10, 3, .runs), pdb(100, 90, 0, 0, .runs),
            pdb(100, 50, 4, 4, .mixed), pdb(149, 0, 0, 0, .doesntRun), pdb(20, 2, 5, 1, .doesntRun),
        ]
        let statuses: [AntiCheatEntry.Status] = [.supported, .running, .planned, .broken, .denied]
        let cheats = [["VAC"], ["Easy Anti-Cheat", "Hyperion"], ["BattlEye", "FACEIT", "Vanguard"]]
        return protondb.flatMap { p in statuses.flatMap { s in cheats.compactMap { AntiCheatSummary(record: record(p, s, cheats: $0)) } } }
    }

    @Test("Every anti-cheat line is about Linux, and none is about the Mac")
    func everyLineIsAboutLinux() {
        let summaries = everySummary
        #expect(summaries.count == 7 * 5 * 3)
        for line in Set(summaries.flatMap(\.lines)) {
            #expect(line.contains("Linux"), "not phrased about Linux: \(line)")
            #expect(line.range(of: "mac", options: .caseInsensitive) == nil, "mentions the Mac: \(line)")
        }
    }

    @Test("Every anti-cheat string in the source names Linux")
    func sourceStringsNameLinux() throws {
        let file = CompatFixture.repo.appending(path: "app/Sources/NotProtonApp/Compatibility/AntiCheatSummary.swift")
        let text = try String(contentsOf: file, encoding: .utf8)
        let strings = text.matches(of: /String\(localized: "([^"]*)"/).map { String($0.output.1) }
        #expect(strings.count == 13)
        for s in strings {
            #expect(s.contains("Linux"), "\(s)")
            #expect(s.range(of: "mac", options: .caseInsensitive) == nil, "\(s)")
        }
    }

    @Test("Online play counts read like the example in the spec")
    func onlineCounts() throws {
        let summary = try #require(AntiCheatSummary(record: record(pdb(456, 402, 26, 26, .runs), .supported, cheats: ["VAC"])))
        #expect(summary.level == .onlineWorks)
        #expect(summary.title == "Online works on Linux, 26 of 26 reports")
        #expect(summary.details == [
            "Runs on Linux in 402 of 456 recent ProtonDB reports.",
            "AreWeAntiCheatYet lists VAC as supported on Linux.",
        ])
    }

    @Test("Apex Legends from the fixture: doesn't run on Linux, with both anti-cheats named")
    func apexLegends() throws {
        let summary = try #require(AntiCheatSummary(record: CompatFixture.data().record(appID: 1172470)))
        #expect(summary.level == .blocked)
        #expect(summary.lines == [
            "Doesn’t run on Linux",
            "149 of 149 recent ProtonDB reports say it doesn’t run on Linux.",
            "No recent ProtonDB report tried online play on Linux.",
            "AreWeAntiCheatYet lists Easy Anti-Cheat and Hyperion as denied on Linux by the developer.",
        ])
    }

    @Test("Elden Ring from the fixture: online works on Linux")
    func eldenRing() throws {
        let summary = try #require(AntiCheatSummary(record: CompatFixture.data().record(appID: 1245620)))
        #expect(summary.title == "Online works on Linux, 9 of 9 reports")
    }

    @Test("A game AreWeAntiCheatYet does not list has no anti-cheat section")
    func noAntiCheat() throws {
        #expect(AntiCheatSummary(record: try CompatFixture.data().record(appID: 632470)) == nil)
    }

    @Test("The Details sheet of any game names the four sources and their licenses", arguments: [1245620, 1172470, 730, 632470, 999_999])
    func detailsNameTheSources(appID: Int) throws {
        let data = try CompatFixture.data()
        let panel = CompatibilityPanel(record: data.record(appID: appID), mac: nil, method: .wine, chip: "M4", data: data, ageNotice: nil)
        #expect(panel.credits == ["MacGamingDB", "AppleGamingWiki (CC BY-NC-SA 3.0)", "ProtonDB (ODbL)", "AreWeAntiCheatYet (MIT)"])
        #expect(panel.sourcesLine
            == "Sources: MacGamingDB, AppleGamingWiki (CC BY-NC-SA 3.0), ProtonDB (ODbL), and AreWeAntiCheatYet (MIT)")
    }

    @Test("The licenses are listed with their attribution")
    func licenses() throws {
        let licenses = CompatibilityCredits.licenses(try CompatFixture.data())
        #expect(licenses.map(\.source) == ["MacGamingDB", "AppleGamingWiki", "ProtonDB", "AreWeAntiCheatYet"])
        #expect(licenses.map(\.license) == ["No data license published", "CC BY-NC-SA 3.0", "ODbL", "MIT"])
        #expect(licenses.allSatisfy { $0.url.hasPrefix("https://") && !$0.attribution.isEmpty })
        #expect(licenses[3].attribution.contains("Copyright (c) 2021 Starz0r, Curve"))
    }
}
