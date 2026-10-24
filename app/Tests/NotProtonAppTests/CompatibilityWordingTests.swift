import Foundation
import Testing
@testable import NotProtonApp

@Suite("Anti-cheat wording and attribution")
struct CompatibilityWordingTests {
    @Test("Known incompatible anti-cheat is shown without an OS comparison")
    func blocked() throws {
        let data = try CompatFixture.data()
        for id in [1172470, 1245620] {
            let summary = try #require(AntiCheatSummary(record: data.record(appID: id)))
            #expect(summary.level == .blocked)
            #expect(summary.title == "Anti-cheat is not compatible with Wine")
            #expect(!summary.lines.joined().contains("Linux"))
            #expect(summary.details.last?.contains("Offline") == true)
        }
    }

    @Test("Unverified anti-cheat stays unverified instead of inheriting positive Proton reports")
    func unknownRemainsUnknown() throws {
        let summary = try #require(MacAntiCheatCatalog.summary(appID: 1238860))
        #expect(summary.level == .untested)
        #expect(summary.title == "Anti-cheat compatibility is unverified")
    }

    @MainActor
    @Test("The shipped Mac catalog supplies Battlefield anti-cheat without the unavailable feed")
    func offlineCatalog() throws {
        let model = CompatibilityModel()
        let panel = model.panel(appID: 2807960, method: .wine)
        #expect(panel.antiCheat?.level == .blocked)
        #expect(panel.antiCheat?.details.first == "EA anticheat")
        #expect(model.panel(appID: 107410, method: .native).antiCheat == nil)
        #expect(model.panel(appID: 730, method: .wine).antiCheat?.level == .untested)
        #expect(MacAntiCheatCatalog.summary(appID: -1) == nil)
    }

    @Test("Unlisted games do not receive a fabricated anticheat verdict")
    func unlisted() throws {
        #expect(AntiCheatSummary(record: try CompatFixture.data().record(appID: 632470)) == nil)
    }

    @Test("ProtonDB multiplayer counts retain their source without overriding incompatibility")
    func protonDBReports() throws {
        let record = try #require(CompatFixture.data().record(appID: 1245620))
        let summary = try #require(AntiCheatSummary(record: record))
            .withProtonDB(record.protondb, appID: 1245620)
        #expect(summary.level == .blocked)
        #expect(summary.protonDBURL?.absoluteString == "https://www.protondb.com/app/1245620")
        #expect(summary.protonDBInfo?.contains("ProtonDB") == true)
        #expect(summary.protonDBInfo?.contains("successful multiplayer reports") == true)
        let missing = summary.withProtonDB(nil, appID: 1245620)
        #expect(missing.protonDBInfo == "No multiplayer reports available from ProtonDB.")
        #expect(missing.level == .blocked)
    }

    @Test("Community sources retain attribution")
    func credits() throws {
        let credits = CompatibilityCredits.credits(try CompatFixture.data())
        #expect(credits.contains("ProtonDB (ODbL)"))
        #expect(credits.contains("AreWeAntiCheatYet (MIT)"))
        #expect(credits.contains("Heroic MacAnticheatData (MIT)"))
    }

    @MainActor
    @Test("The bundled ProtonDB export supplies multiplayer counts while the feed is unavailable")
    func bundledProtonDB() throws {
        let model = CompatibilityModel()
        let summary = try #require(model.panel(appID: 1238860, method: .wine).antiCheat)
        #expect(summary.level == .untested)
        let entry = try #require(ProtonDBCatalog.entry(appID: 1238860, current: nil))
        #expect(entry.onlineTried > 0)
        #expect(summary.protonDBInfo?.contains("\(entry.onlinePlayed)/\(entry.onlineTried)") == true)
        #expect(summary.protonDBURL?.host == "www.protondb.com")
        let newer = ProtonDBEntry(fetched: "2099-01-01", since: "2098-01-01", reports: 2,
                                  works: 0, onlineTried: 2, onlinePlayed: 0, verdict: .doesntRun)
        #expect(ProtonDBCatalog.entry(appID: 1238860, current: newer)?.onlinePlayed == 0)
        #expect(ProtonDBCatalog.entry(appID: 1238860, current: nil)?.onlinePlayed == entry.onlinePlayed)
    }

    @MainActor
    @Test("An unknown VAC verdict is not replaced by a blanket incompatibility rule")
    func vacIsNotAutomaticallyBlocked() throws {
        let model = CompatibilityModel()
        let summary = try #require(model.antiCheat(appID: 730))
        #expect(summary.level == .untested)
        #expect(summary.title == "Anti-cheat compatibility is unverified")
        #expect(summary.details.first == "VAC")
        #expect(summary.protonDBInfo?.contains("ProtonDB") == true)
        #expect(summary.protonDBURL?.absoluteString == "https://www.protondb.com/app/730")
    }
}
