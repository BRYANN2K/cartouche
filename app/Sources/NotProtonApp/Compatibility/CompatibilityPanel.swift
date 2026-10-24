
import Foundation

struct CompatibilityPanel: Sendable {

    let macReportsOn: Bool
    let mac: MacGamingDBEntry?
    let wiki: AppleGamingWikiEntry?
    let estimate: CompatEstimate.Result
    let antiCheat: AntiCheatSummary?
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
}

extension CompatibilityModel {

    func panel(appID: Int, method: PlayMethod) -> CompatibilityPanel {
        CompatibilityPanel(
            record: record(appID: appID), mac: macReports[appID], macReportsOn: choices.fetchMacReports,
            method: method, chip: chip, data: data, ageNotice: busyNotice ?? ageNotice)
    }
}
