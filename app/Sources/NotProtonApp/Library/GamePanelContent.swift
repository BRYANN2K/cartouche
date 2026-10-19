// What the game panel and its Details sheet show, in order. The panel answers: can I
// play it, how fast, with which setup. Sources and rare settings go behind Details.

import Foundation

struct LayerReport: Equatable, Sendable, Identifiable {
    let layer: TranslationLayer
    let count: Int
    // MacGamingDB's 0 to 5 scale
    let average: Double

    var id: TranslationLayer { layer }
}

enum GraphicsReports {

    // Reports of Windows games run through Wine, by layer, most reported first
    static func layers(_ entry: MacGamingDBEntry?) -> [LayerReport] {
        var groups: [TranslationLayer: [Int]] = [:]
        for report in entry?.reports ?? [] where report.method == .wine {
            if let layer = report.layer { groups[layer, default: []].append(report.rating) }
        }
        let order: [TranslationLayer] = [.d3dmetal, .dxmt, .dxvk]
        return groups.map { LayerReport(layer: $0.key, count: $0.value.count,
                                        average: Double($0.value.reduce(0, +)) / Double($0.value.count)) }
            .sorted { ($0.count, -(order.firstIndex(of: $0.layer) ?? order.count))
                    > ($1.count, -(order.firstIndex(of: $1.layer) ?? order.count)) }
    }

    // Best average among layers with at least 5 reports, else the most reported
    static func best(_ layers: [LayerReport]) -> TranslationLayer? {
        let solid = layers.filter { $0.count >= 5 }
        if let top = solid.max(by: { $0.average < $1.average }) { return top.layer }
        return layers.first?.layer
    }
}

struct GamePanelContent {

    enum Section: String, Sendable {
        case play, yourPlay, expected, antiCheat, graphics, setup

        var title: String {
            switch self {
            case .play: String(localized: "Play")
            case .yourPlay: String(localized: "Your Play")
            case .expected: String(localized: "Expected on This Mac")
            case .antiCheat: String(localized: "Anti-Cheat on Linux")
            case .graphics: String(localized: "Graphics Reported on Macs")
            case .setup: String(localized: "Setup")
            }
        }
    }

    enum DetailsSection: String, Sendable {
        case expected, macPicker, allReports, appleGamingWiki, antiCheat, advanced, sources

        var title: String {
            switch self {
            case .expected: String(localized: "Expected on This Mac")
            case .macPicker: String(localized: "Mac")
            case .allReports: String(localized: "All Mac Reports")
            case .appleGamingWiki: "AppleGamingWiki"
            case .antiCheat: String(localized: "Anti-Cheat on Linux")
            case .advanced: String(localized: "Advanced")
            case .sources: String(localized: "Sources")
            }
        }
    }

    let game: Game
    let compat: CompatibilityPanel
    let layers: [LayerReport]
    let bestLayer: TranslationLayer?
    let setup: GameSetupChoice
    // The user's own sessions, measured by the frame counter
    let play: GamePlay?

    init(game: Game, compat: CompatibilityPanel, setup: GameSetupChoice, play: GamePlay? = nil) {
        self.game = game
        self.compat = compat
        layers = GraphicsReports.layers(compat.mac)
        bestLayer = GraphicsReports.best(layers)
        self.setup = setup
        self.play = play
    }

    var playLabel: String { game.installed ? String(localized: "Play") : String(localized: "Install") }

    // Your Play once the game has a session
    var sections: [Section] {
        var out: [Section] = [.play]
        if play != nil { out.append(.yourPlay) }
        out.append(.expected)
        if compat.antiCheat != nil { out.append(.antiCheat) }
        if !layers.isEmpty { out.append(.graphics) }
        out.append(.setup)
        return out
    }

    var detailsSections: [DetailsSection] {
        var out: [DetailsSection] = [.expected, .macPicker]
        if compat.mac?.rating != nil || !layers.isEmpty { out.append(.allReports) }
        if compat.wiki != nil { out.append(.appleGamingWiki) }
        if compat.antiCheat != nil { out.append(.antiCheat) }
        out += [.advanced, .sources]
        return out
    }

    // "Steam. Played yesterday."
    func subtitle(now: Date = Date()) -> String {
        String(localized: "\(game.source.name). \(game.status(now: now)).")
    }

    // A suggestion only when it changes something
    var suggestedBackend: GraphicsBackend? {
        guard let best = bestLayer.flatMap(GraphicsBackend.init) else { return nil }
        return best == (setup.graphics ?? .d3dmetal) ? nil : best
    }

    struct Estimate: Equatable {
        let rating: String
        let fps: String
        let settings: String
        let note: String
    }

    // The three numbers, or nil with the line to show instead
    static func estimate(_ result: CompatEstimate.Result, macReportsOn: Bool) -> (Estimate?, String?) {
        guard macReportsOn else { return (nil, String(localized: "Mac reports are turned off in Settings > Privacy")) }
        switch result {
        case .noReports: return (nil, String(localized: "No reports yet for this version"))
        case .unknownMac: return (nil, String(localized: "No estimate for this Mac yet"))
        case .estimate(let e):
            let note = e.reportCount == 1
                ? String(localized: "1 report from Macs like yours")
                : String(localized: "\(e.reportCount) reports from Macs like yours")
            return (Estimate(
                rating: e.rating.label,
                fps: e.fps.map { String(localized: "\($0) fps") } ?? String(localized: "No data"),
                settings: e.settings?.label ?? String(localized: "Unknown"),
                note: note), nil)
        }
    }

    // AppleGamingWiki's ways to run a game, in the order the sheet lists them
    static let wikiMethods = ["native", "rosetta2", "crossover", "wine", "parallels"]

    static func wikiMethod(_ key: String) -> String {
        switch key {
        case "native": String(localized: "Native")
        case "rosetta2": "Rosetta 2"
        case "crossover": "CrossOver"
        case "wine": "Wine"
        case "parallels": "Parallels"
        default: key
        }
    }

    static func wikiRows(_ ratings: [String: String]) -> [(String, String)] {
        ratings.sorted { (wikiMethods.firstIndex(of: $0.key) ?? 99, $0.key) < (wikiMethods.firstIndex(of: $1.key) ?? 99, $1.key) }
            .map { (wikiMethod($0.key), wikiLabel($0.value)) }
    }

    static func wikiLabel(_ rating: String) -> String {
        switch rating.lowercased() {
        case "perfect": String(localized: "Perfect")
        case "playable": String(localized: "Playable")
        case "runs": String(localized: "Runs")
        case "unplayable": String(localized: "Unplayable")
        case "na", "n/a": String(localized: "Not available")
        default: String(localized: "Untested")
        }
    }

    static func reportCount(_ n: Int) -> String {
        n == 1 ? String(localized: "1 report") : String(localized: "\(n) reports")
    }
}
