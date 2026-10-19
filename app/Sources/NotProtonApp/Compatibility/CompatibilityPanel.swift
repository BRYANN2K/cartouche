// The compatibility part of a game's panel, ready to show

import Foundation

struct CompatibilityPanel: Sendable {

    let macReportsOn: Bool
    let mac: MacGamingDBEntry?
    let wiki: AppleGamingWikiEntry?
    let estimate: CompatEstimate.Result
    let antiCheat: AntiCheatSummary?
    // Every source, named on every panel and Details sheet that shows community data
    let credits: [String]
    let sourcesLine: String?
    let ageNotice: String?

    init(
        record: CompatRecord?, mac: MacGamingDBEntry?, macReportsOn: Bool = true,
        method: PlayMethod, chip: String?, data: CompatData?, ageNotice: String?
    ) {
        self.macReportsOn = macReportsOn
        self.mac = macReportsOn ? mac : nil
        wiki = record?.applegamingwiki
        estimate = CompatEstimate.compute(
            reports: self.mac?.reports ?? [], method: method, chip: chip, gpu: data?.gpuStrength ?? [:])
        antiCheat = AntiCheatSummary(record: record)
        credits = CompatibilityCredits.credits(data)
        sourcesLine = CompatibilityCredits.sourcesLine(data)
        self.ageNotice = ageNotice
    }

    // MacGamingDB's own rating and the layer most reports name
    var macLines: [String] {
        guard let mac, let rating = mac.rating else { return [] }
        return [rating.label] + (mac.topLayer.map { [String(localized: "Most reported layer: \($0.label)")] } ?? [])
    }

    // No number is shown without reports
    var estimateLines: [String] {
        guard macReportsOn else { return [String(localized: "Mac reports are turned off in Settings > Privacy")] }
        switch estimate {
        case .noReports:
            return [String(localized: "No reports yet for this version")]
        case .unknownMac:
            return [String(localized: "No estimate for this Mac yet")]
        case .estimate(let e):
            var lines = [e.rating.label]
            if let fps = e.fps { lines.append(String(localized: "About \(fps) fps")) }
            if let settings = e.settings { lines.append(String(localized: "\(settings.label) settings")) }
            lines.append(e.sameChipCount > 0
                ? String(localized: "Reports used: \(e.reportCount), including \(e.sameChipCount) on \(e.chip)")
                : String(localized: "Reports used: \(e.reportCount), all from other Macs"))
            return lines
        }
    }
}

extension CompatibilityModel {

    func panel(appID: Int, method: PlayMethod) -> CompatibilityPanel {
        CompatibilityPanel(
            record: record(appID: appID), mac: macReports[appID], macReportsOn: choices.fetchMacReports,
            method: method, chip: chip, data: data, ageNotice: ageNotice)
    }
}
