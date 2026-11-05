import Foundation

// What's New copy lives in WhatsNew.xcstrings, French and English only; other languages read English
enum WhatsNewText {
    static let table = "WhatsNew"
    nonisolated(unsafe) static var bundle: Bundle = .module
    nonisolated(unsafe) static var language = Bundle.module.preferredLocalizations.first == "fr" ? "fr" : "en"

    // Snapshots and tests pin a language whatever the Mac's
    static func use(language: String) {
        guard let path = Bundle.module.path(forResource: language, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return }
        self.bundle = bundle
        self.language = language
    }

    static func string(_ key: String, _ arguments: CVarArg...) -> String {
        let format = bundle.localizedString(forKey: key, value: nil, table: table)
        return arguments.isEmpty ? format : String(format: format, locale: Locale(identifier: language), arguments: arguments)
    }
}
