import Foundation

// Translate the screen: RetroArch's AI service sends a picture of the game to
// a translation service and draws the answer over it. Cartouche names no
// service and runs none; the user sets the address of one they choose.
public struct TranslationSetup: Sendable, Equatable {
    public var service: URL
    // RetroArch's number for the language to translate into
    public var targetLanguage: Int

    public init(service: URL, targetLanguage: Int) {
        self.service = service
        self.targetLanguage = targetLanguage
    }

    // An http or https address with a host; anything else is not a service
    public static func service(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.host?.isEmpty == false
        else { return nil }
        return url
    }

    // RetroArch's translation_lang numbers (translation_defines.h), for the
    // Mac's own language; English when RetroArch has no number for it
    public static func language(_ locale: Locale = .current) -> Int {
        let code = locale.language.languageCode?.identifier ?? "en"
        if code == "zh" {
            return locale.language.script?.identifier == "Hant" ? 14 : 13
        }
        return ["en": 1, "es": 2, "fr": 3, "it": 4, "de": 5, "ja": 6, "nl": 7, "cs": 8, "da": 9, "sv": 10,
                "hr": 11, "ko": 12][code] ?? 1
    }
}
