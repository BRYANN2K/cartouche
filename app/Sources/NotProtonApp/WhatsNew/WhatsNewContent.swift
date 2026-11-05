import Foundation
import Observation

// One version's pages, read from Resources/WhatsNew/whats-new.json. Texts are keys in WhatsNew.xcstrings.
struct WhatsNewRelease: Codable, Equatable, Identifiable, Sendable {
    var version: String
    var pages: [WhatsNewPage]

    var id: String { version }
}

struct WhatsNewPage: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var image: String
    var title: String
    var line: String
    var alt: String
    // Drawn in the label colour where the line has %@
    var shortcut: String?
    var soon: Bool?

    var isSoon: Bool { soon ?? false }
}

enum WhatsNewCatalog {
    static let folder = "WhatsNew"

    static let bundled: [WhatsNewRelease] = load(Bundle.module.url(forResource: "whats-new", withExtension: "json", subdirectory: folder))

    static func load(_ url: URL?) -> [WhatsNewRelease] {
        struct File: Decodable { var releases: [WhatsNewRelease] }
        guard let url, let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data) else { return [] }
        return file.releases.filter { !$0.pages.isEmpty }
    }

    // The newest content at or below the app's version: 0.2.0-beta1's stays current through 0.2.0
    static func release(for appVersion: String, in releases: [WhatsNewRelease] = bundled) -> WhatsNewRelease? {
        guard appVersion.first?.isNumber == true else { return nil }
        return releases
            .filter { CartoucheVersion.compare($0.version, appVersion) != .orderedDescending }
            .max { CartoucheVersion.compare($0.version, $1.version) == .orderedAscending }
    }

    // The page's capture in the shown language, English when there is none
    static func imageURL(_ name: String, language: String, bundle: Bundle = .module) -> URL? {
        bundle.url(forResource: "\(name).\(language)", withExtension: "jpg", subdirectory: folder)
            ?? bundle.url(forResource: "\(name).en", withExtension: "jpg", subdirectory: folder)
    }
}

enum WhatsNewGate {
    static let lastSeenKey = "whatsNew.lastSeen"

    enum Decision: Equatable {
        case show(WhatsNewRelease)
        // A fresh install meets onboarding instead; its content counts as seen
        case markSeen(String)
        case nothing
    }

    static func decide(appVersion: String, lastSeen: String?, onboardingDue: Bool,
                       releases: [WhatsNewRelease] = WhatsNewCatalog.bundled) -> Decision {
        guard let release = WhatsNewCatalog.release(for: appVersion, in: releases) else { return .nothing }
        if let lastSeen, CartoucheVersion.compare(lastSeen, release.version) != .orderedAscending { return .nothing }
        return onboardingDue ? .markSeen(release.version) : .show(release)
    }
}

@MainActor
@Observable
final class WhatsNewModel {
    var shown: WhatsNewRelease?
    let appVersion: String
    private let releases: [WhatsNewRelease]
    private let defaults: UserDefaults

    init(appVersion: String = AppVersion.bundled, releases: [WhatsNewRelease] = WhatsNewCatalog.bundled,
         defaults: UserDefaults = .standard) {
        self.appVersion = appVersion
        self.releases = releases
        self.defaults = defaults
    }

    var current: WhatsNewRelease? { WhatsNewCatalog.release(for: appVersion, in: releases) }

    var lastSeen: String? { defaults.string(forKey: WhatsNewGate.lastSeenKey) }

    func presentIfDue(onboardingDue: Bool) {
        switch WhatsNewGate.decide(appVersion: appVersion, lastSeen: lastSeen, onboardingDue: onboardingDue, releases: releases) {
        case .show(let release):
            defaults.set(release.version, forKey: WhatsNewGate.lastSeenKey)
            shown = release
        case .markSeen(let version):
            defaults.set(version, forKey: WhatsNewGate.lastSeenKey)
        case .nothing:
            break
        }
    }

    // Help > What's New…
    func reopen() {
        shown = current
    }
}
