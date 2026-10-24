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

    @Test("Elden Ring on an M4: Good, about 53 fps, High, from 7 reports on M4")
    func eldenRingOnM4() throws {
        guard case .estimate(let e) = try eldenRing(on: "M4") else { Issue.record("no estimate"); return }
        #expect(e.rating == .good)
        #expect(e.fps == 53)
        #expect(e.settings == .high)
        #expect(e.reportCount == 7)
        #expect(e.sameChipCount == 7)
    }

    @Test("The panel says it in words, with the number of reports")
    func eldenRingPanelLines() throws {
        let data = try CompatFixture.data()
        let panel = CompatibilityPanel(record: data.record(appID: 1245620), mac: try CompatFixture.eldenRingMac(),
                                       method: .wine, chip: "M4", data: data, ageNotice: nil)
        let (estimate, line) = GamePanelContent.estimate(panel.estimate, macReportsOn: panel.macReportsOn)
        #expect(line == nil)
        #expect(estimate == GamePanelContent.Estimate(
            rating: "Good", fps: "53 fps", settings: "High", note: "7 reports from Macs like yours"))
    }

    @Test("Comparable Macs are within 1.4 times the GPU strength either way")
    func comparableWindow() {
        var gpu = ["M1": 1.0, "A": 1.0 / 1.39, "B": 1.39, "C": 1.0 / 1.41, "D": 1.41]
        let reports = gpu.keys.map { MacReport(chip: $0, method: .wine, layer: nil, rating: 3, fps: 60, settings: nil, date: "2026-01-01") }
        gpu["Target"] = 1
        guard case .estimate(let e) = CompatEstimate.compute(reports: reports, method: .wine, chip: "Target", gpu: gpu) else {
            Issue.record("no estimate"); return
        }
        #expect(e.reportCount == 3)
    }

    @Test("Without comparable reports, use the nearest available model and identify the fallback")
    func fallbackToClosest() throws {
        guard case .estimate(let e) = try eldenRing(on: "M3 Ultra") else { Issue.record("no estimate"); return }
        #expect(e.reportCount == 3)
        #expect(e.sameChipCount == 0)
        let data = try CompatFixture.data()
        let panel = CompatibilityPanel(record: data.record(appID: 1245620), mac: try CompatFixture.eldenRingMac(),
                                       method: .wine, chip: "M3 Ultra", data: data, ageNotice: nil)
        let (estimate, _) = GamePanelContent.estimate(panel.estimate, macReportsOn: panel.macReportsOn)
        #expect(estimate?.note == "Based on the closest available Mac reports")
    }

    @Test("Changing Mac changes the report population rather than averaging every sparse report")
    func selectedMacPopulation() {
        let reports = [
            MacReport(chip: "M3", method: .wine, layer: .d3dmetal, rating: 5, fps: 120, settings: .ultra, date: "2026-01-01"),
            MacReport(chip: "M5 Pro", method: .wine, layer: .d3dmetal, rating: 5, fps: 90, settings: .ultra, date: "2026-01-01")
        ]
        let gpu = MacGPUProfiles.bundled
        guard case .estimate(let base) = CompatEstimate.compute(reports: reports, method: .wine, chip: "M4", gpu: gpu),
              case .estimate(let max) = CompatEstimate.compute(reports: reports, method: .wine, chip: "M2 Max", gpu: gpu) else {
            Issue.record("Missing estimates"); return
        }
        #expect(base.fps == 120)
        #expect(max.fps == 90)
        #expect(base.reportCount == 1 && max.reportCount == 1)
    }

    @Test("A Mac without an exact native report uses a comparable Mac average")
    func nativeComparableAverage() {
        let reports = [40, 50].enumerated().map { index, fps in
            MacReport(chip: index == 0 ? "M4" : "M5", method: .native, layer: nil, rating: 3, fps: fps, settings: .low, date: "2026-01-01")
        }
        guard case .estimate(let result) = CompatEstimate.compute(reports: reports, method: .native, chip: "M2 Pro", gpu: MacGPUProfiles.bundled) else {
            Issue.record("Missing native estimate"); return
        }
        #expect(result.fps == 45 && result.reportCount == 2)
        #expect(CompatEstimate.compute(reports: reports, method: .wine, chip: "M2 Pro", gpu: MacGPUProfiles.bundled) == .noReports)
    }

    @Test("No reports for the play method: the panel says so and shows no number")
    func noReports() throws {
        #expect(try eldenRing(on: "M4", method: .native) == .noReports)
        let data = try CompatFixture.data()
        let elden = try CompatFixture.eldenRingMac()
        for (app, mac, method) in [(1245620, elden, PlayMethod.native), (1172470, MacGamingDBEntry.empty, .wine), (999_999, nil, .wine)] {
            let panel = CompatibilityPanel(record: data.record(appID: app), mac: mac, method: method, chip: "M4", data: data, ageNotice: nil)
            let (estimate, line) = GamePanelContent.estimate(panel.estimate, macReportsOn: panel.macReportsOn)
            #expect(estimate == nil)
            #expect(line == "No reports yet for this version")
        }
    }

    @Test("A Mac missing from the strength table gets no estimate")
    func unknownMac() throws {
        #expect(try eldenRing(on: nil) == .unknownMac)
        #expect(try eldenRing(on: "M9 Max") == .unknownMac)
    }

    @Test("A missing compatibility feed still allows estimates from Mac reports")
    func bundledGPUProfiles() throws {
        let gpu = MacGPUProfiles.current(nil)
        #expect(gpu["M4"] != nil)
        let reports = try CompatFixture.eldenRingMac().reports
        guard case .estimate(let estimate) = CompatEstimate.compute(reports: reports, method: .wine, chip: "M4", gpu: gpu) else {
            Issue.record("The bundled profiles must support MacGamingDB reports without the remote feed")
            return
        }
        #expect(estimate.reportCount > 0)
        #expect(MacGPUProfiles.current(["M4": .nan])["M4"] == gpu["M4"])
        #expect(MacGPUProfiles.current(["M4": 2.0])["M4"] == 2.0)
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
