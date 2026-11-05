import Foundation

// The menu's copy lives in its own table, Overlay.xcstrings, so its French follows the
// mockup word for word without touching the app's strings
enum OverlayText {
    nonisolated(unsafe) static var bundle: Bundle = .module
    nonisolated(unsafe) static var locale = Locale.current
    // The app's language, which the in-game HUD follows
    nonisolated(unsafe) static var language = Bundle.module.preferredLocalizations.first ?? "en"

    // Snapshots and tests pin a language whatever the Mac's
    static func use(language: String) {
        guard let path = Bundle.module.path(forResource: language, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return }
        self.bundle = bundle
        locale = Locale(identifier: language)
        self.language = language
    }

    static var french: Bool { locale.language.languageCode?.identifier == "fr" }
}

func ot(_ key: String.LocalizationValue) -> String {
    String(localized: key, table: "Overlay", bundle: OverlayText.bundle, locale: OverlayText.locale)
}

// Numbers as the mockup writes them: decimal comma and a narrow no-break space before units in French
enum OverlayFormat {
    static let space = "\u{202F}"

    static func decimal(_ value: Double, digits: Int = 1) -> String {
        guard value.isFinite else { return "—" }
        let text = String(format: "%.\(digits)f", value)
        return OverlayText.french ? text.replacingOccurrences(of: ".", with: ",") : text
    }

    static func whole(_ value: Double) -> String {
        value.isFinite ? String(Int(value.rounded())) : "—"
    }

    static func percent(_ value: Double) -> String { whole(value) + (OverlayText.french ? space : "") + "%" }

    static func unit(_ number: String, _ unit: String) -> String { number + space + unit }
}
