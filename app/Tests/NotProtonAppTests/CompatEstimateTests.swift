import Foundation
import Testing

@testable import NotProtonApp

@Suite("Per-Mac estimate")
struct CompatEstimateTests {

    private func eldenRing(on chip: String?, method: PlayMethod = .wine) throws -> CompatEstimate.Result {
        let data = try CompatFixture.data()
        let reports = try CompatFixture.eldenRingMac().reports
        return CompatEstimate.compute(reports: reports, method: method, chip: chip, gpu: data.gpuStrength)
    }

    @Test("Elden Ring on an M4: Good, about 52 fps, High, from 13 reports including 7 on M4")
    func eldenRingOnM4() throws {
        guard case .estimate(let e) = try eldenRing(on: "M4") else { Issue.record("no estimate"); return }
        #expect(e.rating == .good)
        #expect(e.fps == 52)
        #expect(e.settings == .high)
        #expect(e.reportCount == 13)
        #expect(e.sameChipCount == 7)
        #expect(!e.usedFallback)
        #expect(e.fpsRange == 40...60)
    }

    @Test("The panel says it in words, with the number of reports")
    func eldenRingPanelLines() throws {
        let data = try CompatFixture.data()
        let panel = CompatibilityPanel(record: data.record(appID: 1245620), mac: try CompatFixture.eldenRingMac(),
                                       method: .wine, chip: "M4", data: data, ageNotice: nil)
        #expect(panel.estimateLines == ["Good", "About 52 fps", "High settings", "Reports used: 13, including 7 on M4"])
    }

    @Test("Comparable Macs are within 1.4 times the GPU strength either way")
    func comparableWindow() {
        let gpu = ["M1": 1.0, "A": 1.0 / 1.39, "B": 1.39, "C": 1.0 / 1.41, "D": 1.41]
        let reports = gpu.keys.map { MacReport(chip: $0, method: .wine, layer: nil, rating: 3, fps: 60, settings: nil, date: "2026-01-01") }
        guard case .estimate(let e) = CompatEstimate.compute(reports: reports, method: .wine, chip: "M1", gpu: gpu) else {
            Issue.record("no estimate"); return
        }
        #expect(e.reportCount == 3)
        #expect(!e.usedFallback)
    }

    @Test("With fewer than 3 comparable reports, the 5 closest are used")
    func fallbackToClosest() throws {
        guard case .estimate(let e) = try eldenRing(on: "M3 Ultra") else { Issue.record("no estimate"); return }
        #expect(e.usedFallback)
        #expect(e.reportCount == 5)
        #expect(e.sameChipCount == 0)
        let data = try CompatFixture.data()
        let panel = CompatibilityPanel(record: data.record(appID: 1245620), mac: try CompatFixture.eldenRingMac(),
                                       method: .wine, chip: "M3 Ultra", data: data, ageNotice: nil)
        #expect(panel.estimateLines.last == "Reports used: 5, all from other Macs")
    }

    @Test("No reports for the play method: the panel says so and shows no number")
    func noReports() throws {
        #expect(try eldenRing(on: "M4", method: .native) == .noReports)
        let data = try CompatFixture.data()
        let elden = try CompatFixture.eldenRingMac()
        for (app, mac, method) in [(1245620, elden, PlayMethod.native), (1172470, MacGamingDBEntry.empty, .wine), (999_999, nil, .wine)] {
            let panel = CompatibilityPanel(record: data.record(appID: app), mac: mac, method: method, chip: "M4", data: data, ageNotice: nil)
            #expect(panel.estimateLines == ["No reports yet for this version"])
            #expect(panel.estimateLines.allSatisfy { $0.rangeOfCharacter(from: .decimalDigits) == nil })
        }
    }

    @Test("A Mac missing from the strength table gets no estimate")
    func unknownMac() throws {
        #expect(try eldenRing(on: nil) == .unknownMac)
        #expect(try eldenRing(on: "M9 Max") == .unknownMac)
    }

    @Test("A tie in settings goes to the one reported first")
    func settingsTie() {
        let rows = [GraphicsSettings.medium, .high, .high, .medium].map {
            MacReport(chip: "M1", method: .wine, layer: nil, rating: 2, fps: nil, settings: $0, date: "2026-01-01")
        }
        guard case .estimate(let e) = CompatEstimate.compute(reports: rows, method: .wine, chip: "M1", gpu: ["M1": 1]) else {
            Issue.record("no estimate"); return
        }
        #expect(e.settings == .medium)
        #expect(e.fps == nil)
        #expect(e.rating == .playable)
    }

    @Test("The chip name is read from the CPU brand string", arguments: [
        ("Apple M4", "M4"), ("Apple M4 Pro", "M4 Pro"), ("Apple M2 Ultra", "M2 Ultra"), ("Apple M1 Max", "M1 Max"),
        ("Apple A18 Pro", "A18 Pro"), ("Intel(R) Core(TM) i9-9980HK CPU @ 2.40GHz", nil),
    ] as [(String, String?)])
    func chipName(brand: String, chip: String?) {
        #expect(MacChip.parse(brand) == chip)
    }

    @Test("This Mac's chip is in the strength table", .enabled(if: MacChip.current() != nil))
    func thisMac() throws {
        let chip = try #require(MacChip.current())
        #expect(try CompatFixture.data().gpuStrength[chip] != nil, "\(chip) is missing from gpu_strength.json")
    }
}
