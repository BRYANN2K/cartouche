import Foundation
import Testing
@testable import NotProtonApp

@MainActor
@Suite("Background apps window")
struct BackgroundAppsTests {

    @Test("Play on an overloaded Mac opens the window; Play plays, Cancel does not")
    func onPlay() {
        let presenter = BackgroundAppsPresenter()
        var played = 0
        presenter.beforePlay(overloaded: false) { played += 1 }
        #expect(played == 1 && presenter.mode == nil)
        presenter.beforePlay(overloaded: true) { played += 1 }
        #expect(played == 1 && presenter.mode == .play)
        presenter.close(play: true)
        #expect(played == 2 && presenter.mode == nil)
        presenter.beforePlay(overloaded: true) { played += 1 }
        presenter.close()
        #expect(played == 2)
    }

    @Test("Coming back to the app offers nothing: the window opens itself only before Play")
    func noAutoOpenOnActivate() {
        let presenter = BackgroundAppsPresenter()
        var opened = 0
        presenter.showMainWindow = { opened += 1 }
        // The window opens itself only before Play; by hand it is the menu, ⌥⌘R or the notification
        var played = 0
        presenter.beforePlay(overloaded: false) { played += 1 }
        #expect(played == 1 && presenter.mode == nil && opened == 0)
        presenter.show()
        #expect(presenter.mode == .manual && opened == 1)
    }

    // d3449860: Cartouche coming back to the front opened the window by itself. The SwiftUI scene
    // does not run in tests, so this reads what its activation handler calls.
    @Test("The app's activation handler never reaches Background Apps, and the window has no mode of its own for it")
    func activationNeverOffers() throws {
        switch BackgroundAppsPresenter.Mode.manual {
        case .manual, .play: break
        }
        let source = try String(contentsOf: Golden.repo.appending(path: "app/Sources/NotProtonApp/App.swift"), encoding: .utf8)
        let handler = try #require(source.range(of: "NSApplication.didBecomeActiveNotification"))
        let rest = source[handler.upperBound...]
        let block = rest[..<(rest.range(of: ".defaultSize")?.lowerBound ?? rest.endIndex)]
        #expect(!block.contains("BackgroundApps") && !block.contains("offer"), "\(block)")
        let models = try String(contentsOf: Golden.repo.appending(path: "app/Sources/NotProtonApp/App/AppModels.swift"), encoding: .utf8)
        #expect(!models.contains("offerBackgroundApps"))
    }

    @Test("« Don't show again this session » stops the Play offer, never the menu or ⌥⌘R")
    func mute() {
        let presenter = BackgroundAppsPresenter()
        presenter.beforePlay(overloaded: true) {}
        presenter.muteChecked = true
        presenter.close()
        #expect(presenter.rules.muted)
        var played = false
        presenter.beforePlay(overloaded: true) { played = true }
        #expect(played && presenter.mode == nil)
        presenter.show()
        #expect(presenter.mode == .manual)
        // Opened by hand, the box is not there and closing changes nothing
        presenter.close()
        #expect(BackgroundAppsRules().onPlay(overloaded: true))
    }

    @Test("Numbers: whole percents, memory always in GB with one decimal, the Mac's RAM as sold")
    func format() {
        let fr = Locale(identifier: "fr_FR"), en = Locale(identifier: "en_US")
        let gib: UInt64 = 1 << 30
        #expect(BackgroundAppsFormat.percent(34.4, locale: fr) == "34")
        #expect(BackgroundAppsFormat.percent(nil) == "—")
        #expect(BackgroundAppsFormat.gigabytes(205 << 20, locale: fr) == "0,2")
        #expect(BackgroundAppsFormat.gigabytes(205 << 20, locale: en) == "0.2")
        #expect(BackgroundAppsFormat.gigabytes(3 * gib, locale: en) == "3.0")
        #expect(BackgroundAppsFormat.gigabytes(1200 * gib, locale: en) == "1200.0")
        #expect(BackgroundAppsFormat.total(24 * gib - 1000) == 24)
        let used = UInt64(17.1 * Double(gib))
        #expect(BackgroundAppsFormat.memory(used: used, physical: 24 * gib, locale: fr) == "17,1 / 24")
        #expect(BackgroundAppsFormat.memory(used: used, physical: 24 * gib, locale: en) == "17.1 / 24")
    }

    @Test("Ce Mac in the in-game menu reads memory as used over total")
    func overlayMemory() {
        OverlayText.use(language: "fr")
        defer { OverlayText.use(language: "en") }
        let gib: UInt64 = 1 << 30
        var mac = MacReadings()
        #expect(MacGroup.memory(mac) == nil)
        mac.memoryUsed = UInt64(17.1 * Double(gib))
        mac.memoryTotal = 24 * gib
        #expect(MacGroup.memory(mac) == "17,1 / 24\u{202F}Go")
    }

    @Test("Rows: Apps lists only what can act, macOS and protected apps marked in Tout, CPU as a share of the Mac")
    func rows() async throws {
        let monitor = try await AppRefreshSnapshotTests.monitor(.normal)
        let apps = monitor.backgroundRows(all: false)
        #expect(apps.first?.usage.name == "Google Chrome")
        #expect(abs((apps.first?.cpu ?? 0) - 34) < 0.5)
        #expect(apps.allSatisfy { $0.kind == .app })
        let all = monitor.backgroundRows(all: true)
        #expect(all.first { $0.usage.name == "Spotlight" }?.kind == .system)
        #expect(all.first { $0.usage.name == "1Password" }?.kind == .protected)
        #expect(!monitor.macOverloaded)
        #expect(try await AppRefreshSnapshotTests.monitor(.over).macOverloaded)
        #expect(LoadThresholds().otherCPU == 60)
    }

    @Test("The column titles sort descending first, a second click reverses")
    func sortColumns() {
        func row(_ name: String, cpu: Double, gpu: Double, memory: UInt64) -> BackgroundAppRow {
            BackgroundAppRow(usage: ResourceUsage(pid: pid_t(name.count), name: name, pids: []),
                             cpu: cpu, gpu: gpu, memory: memory, kind: .app, paused: false)
        }
        let rows = [row("A", cpu: 10, gpu: 40, memory: 2), row("B", cpu: 50, gpu: 10, memory: 1),
                    row("C", cpu: 30, gpu: 20, memory: 3)]
        var sort = AppsSort()
        #expect(BackgroundAppRow.sorted(rows, by: sort).map(\.usage.name) == ["B", "C", "A"])
        sort.tap(.cpu)
        #expect(BackgroundAppRow.sorted(rows, by: sort).map(\.usage.name) == ["A", "C", "B"])
        sort.tap(.gpu)
        #expect(BackgroundAppRow.sorted(rows, by: sort).map(\.usage.name) == ["A", "C", "B"])
        sort.tap(.memory)
        #expect(BackgroundAppRow.sorted(rows, by: sort).map(\.usage.name) == ["C", "A", "B"])
    }

    @Test("Every word of the window, the game page and the settings tab has French, and the old words are gone")
    func copyComplete() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appending(path: "Sources/NotProtonApp")
        let catalogs = sources.appending(path: "Resources/Localization")
        func strings(_ name: String) throws -> [String: Any] {
            let json = try JSONSerialization.jsonObject(with: Data(contentsOf: catalogs.appending(path: name))) as? [String: Any]
            return json?["strings"] as? [String: Any] ?? [:]
        }
        func french(_ table: [String: Any], _ key: String) -> String? {
            let fr = ((table[key] as? [String: Any])?["localizations"] as? [String: Any])?["fr"] as? [String: Any]
            return (fr?["stringUnit"] as? [String: Any])?["value"] as? String
        }
        let overlay = try strings("Overlay.xcstrings"), app = try strings("Localizable.xcstrings")
        let files = ["SystemLoad/BackgroundApps.swift", "SystemLoad/BackgroundAppsView.swift", "Library/Views/AdvancedGameRows.swift",
                     "Library/Views/InGameMenuSettingsView.swift", "Library/Views/GamePanel.swift", "App/AppCommands.swift",
                     "App/StatusItemMenu.swift"]
        var menuKeys: Set<String> = [], appKeys: Set<String> = []
        for file in files {
            let text = try String(contentsOf: sources.appending(path: file), encoding: .utf8)
            for m in text.matches(of: #/ot\("([^"]+)"\)/#) { menuKeys.insert(String(m.1)) }
            for m in text.matches(of: #/(?:Text|Button|String\(localized:)\(?\s*"([^"\\]+)"\s*[),{]/#) { appKeys.insert(String(m.1)) }
        }
        #expect(menuKeys.count > 40)
        for key in menuKeys { #expect(french(overlay, key)?.isEmpty == false, "no French for \(key)") }
        for key in appKeys where key.contains(where: \.isLetter) {
            #expect(french(app, key)?.isEmpty == false, "no French for \(key)")
        }
        let retired = ["Ressources du Mac", "Mise à l’échelle", "Images générées", "Spatiale", "Temporelle", "Spatial", "Temporel"]
        for table in [overlay, app, try strings("WhatsNew.xcstrings")] {
            for key in table.keys {
                let value = french(table, key) ?? ""
                #expect(!retired.contains { value.contains($0) }, "\(key) still says \(value)")
            }
        }
    }
}
