import Foundation
import Testing

@testable import NotProtonApp

@Suite("Game dates")
struct GameDatesTests {

    private let now = CompatDate.instant("2026-10-29T12:00:00Z")!

    private func ago(days: Int) -> String {
        GameDates.relative(Calendar.current.date(byAdding: .day, value: -days, to: now)!, now: now)
    }

    @Test("Short spans count days")
    func days() {
        #expect(ago(days: 0) == "today")
        #expect(ago(days: 1) == "yesterday")
        #expect(ago(days: 7) == "7 days ago")
        #expect(ago(days: 13) == "13 days ago")
    }

    // Apex Legends in the report: Steam's LastPlayed 1653858293 read as "1.614 days ago"
    @Test("Longer spans use the largest unit")
    func largestUnit() {
        #expect(ago(days: 20) == "2 weeks ago")
        #expect(ago(days: 75) == "2 months ago")
        #expect(GameDates.relative(SteamLocalFiles.date(1_653_858_293)!, now: now) == "4 years ago")
    }
}
