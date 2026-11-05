import Foundation
import Testing
@testable import NotProtonApp

// « Apps en arrière-plan » is « Background Apps » in English, in title case: tab, window, Window menu, What's New
@MainActor
@Suite("English copy")
struct EnglishCopyTests {
    func table(_ name: String) throws -> [String: Any] {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appending(path: "Sources/NotProtonApp/Resources/Localization/\(name)")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        return json?["strings"] as? [String: Any] ?? [:]
    }

    func value(_ entry: Any?, _ language: String) -> String? {
        let loc = ((entry as? [String: Any])?["localizations"] as? [String: Any])?[language] as? [String: Any]
        return (loc?["stringUnit"] as? [String: Any])?["value"] as? String
    }

    @Test("Wherever the French says « Apps en arrière-plan », the English says « Background Apps »")
    func backgroundApps() throws {
        var seen = 0
        for name in ["Localizable.xcstrings", "Overlay.xcstrings", "WhatsNew.xcstrings"] {
            for (key, entry) in try table(name) {
                guard let fr = value(entry, "fr"), fr.localizedCaseInsensitiveContains("apps en arrière-plan") else { continue }
                let en = value(entry, "en") ?? key
                #expect(en.contains("Background Apps"), "\(name) \(key): \(en)")
                #expect(!en.contains("Resources"), "\(name) \(key): \(en)")
                seen += 1
            }
        }
        #expect(seen >= 8)
    }

    @Test("The menu's tab and the window title read « Background Apps » in English")
    func overlayTab() {
        defer { OverlayText.use(language: "en") }
        OverlayText.use(language: "en")
        #expect(OverlaySection.resources.title == "Background Apps")
        #expect(OverlaySection.resources.short == "Apps")
        #expect(ot("Mac Resources") == "Background Apps")
        OverlayText.use(language: "fr")
        #expect(OverlaySection.resources.title == "Apps en arrière-plan")
    }
}
