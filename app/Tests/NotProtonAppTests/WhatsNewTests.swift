import Foundation
import Testing
@testable import NotProtonApp

private func scratchDefaults() -> UserDefaults {
    let name = "whatsnew-tests-\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return d
}

private func release(_ version: String) -> WhatsNewRelease {
    WhatsNewRelease(version: version, pages: [WhatsNewPage(id: "a", image: "a", title: "t", line: "l", alt: "x")])
}

@Suite("What's New gating")
struct WhatsNewGateTests {
    let releases = [release("0.2.0-beta1")]

    @Test("An update from a version without What's New shows it once onboarding is done")
    func updateShows() {
        #expect(WhatsNewGate.decide(appVersion: "0.2.0-beta1", lastSeen: nil, onboardingDue: false, releases: releases)
            == .show(releases[0]))
    }

    @Test("A fresh install meets onboarding instead and counts the content as seen")
    func freshInstallMarksSeen() {
        #expect(WhatsNewGate.decide(appVersion: "0.2.0-beta1", lastSeen: nil, onboardingDue: true, releases: releases)
            == .markSeen("0.2.0-beta1"))
    }

    @Test("Content seen in a beta is not shown again by the next beta or the release")
    func seenOnce() {
        for version in ["0.2.0-beta1", "0.2.0-beta.1", "0.2.0-beta2", "0.2.0", "0.2.1"] {
            #expect(WhatsNewGate.decide(appVersion: version, lastSeen: "0.2.0-beta1", onboardingDue: false, releases: releases) == .nothing)
        }
    }

    @Test("A version older than any content, or a dev build, shows nothing")
    func noContent() {
        for version in ["0.1.2", "0.1.0-dev", "0.2.0-alpha", "garbage", ""] {
            #expect(WhatsNewGate.decide(appVersion: version, lastSeen: nil, onboardingDue: false, releases: releases) == .nothing)
        }
    }

    @Test("A later version with its own content shows the newest one only")
    func newestContent() {
        let both = [release("0.2.0"), release("0.3.0")]
        #expect(WhatsNewGate.decide(appVersion: "0.3.0", lastSeen: "0.2.0", onboardingDue: false, releases: both) == .show(both[1]))
        #expect(WhatsNewGate.decide(appVersion: "0.3.0", lastSeen: nil, onboardingDue: false, releases: both) == .show(both[1]))
        #expect(WhatsNewGate.decide(appVersion: "0.2.5", lastSeen: nil, onboardingDue: false, releases: both) == .show(both[0]))
    }

    @Test("The model stores what it showed, shows it once, and Help reopens it")
    @MainActor
    func modelOnce() {
        let defaults = scratchDefaults()
        let model = WhatsNewModel(appVersion: "0.2.0-beta1", releases: releases, defaults: defaults)
        model.presentIfDue(onboardingDue: false)
        #expect(model.shown == releases[0])
        #expect(defaults.string(forKey: WhatsNewGate.lastSeenKey) == "0.2.0-beta1")
        model.shown = nil
        let next = WhatsNewModel(appVersion: "0.2.0-beta2", releases: releases, defaults: defaults)
        next.presentIfDue(onboardingDue: false)
        #expect(next.shown == nil)
        next.reopen()
        #expect(next.shown == releases[0])
    }

    @Test("On a fresh install the model shows nothing, then nothing at the next launch either")
    @MainActor
    func modelFreshInstall() {
        let defaults = scratchDefaults()
        let first = WhatsNewModel(appVersion: "0.2.0-beta1", releases: releases, defaults: defaults)
        first.presentIfDue(onboardingDue: true)
        #expect(first.shown == nil)
        let second = WhatsNewModel(appVersion: "0.2.0-beta2", releases: releases, defaults: defaults)
        second.presentIfDue(onboardingDue: false)
        #expect(second.shown == nil)
    }
}

@Suite("What's New content")
struct WhatsNewContentTests {
    @Test("0.2.0-beta1 has the five validated pages, « Bientôt » last and only there")
    func bundledRelease() throws {
        let release = try #require(WhatsNewCatalog.release(for: "0.2.0-beta1"))
        #expect(release.version == "0.2.0-beta1")
        #expect(WhatsNewCatalog.release(for: "0.2.0-beta.1") == release)
        #expect(WhatsNewCatalog.release(for: "0.2.0") == release)
        #expect(WhatsNewCatalog.release(for: "0.1.2") == nil)
        #expect(release.pages.map(\.id) == ["menu", "upscaling", "hud", "resources", "framegen"])
        #expect(release.pages.map(\.isSoon) == [false, false, false, false, true])
        #expect(release.pages.map(\.shortcut) == ["⌥C", nil, "⌥⇧C", nil, nil])
    }

    @Test("Every page has its capture bundled for French and English")
    func imagesBundled() throws {
        for release in WhatsNewCatalog.bundled {
            for page in release.pages {
                for language in ["fr", "en"] {
                    let url = try #require(WhatsNewCatalog.imageURL(page.image, language: language))
                    #expect(url.lastPathComponent == "\(page.image).\(language).jpg")
                }
            }
        }
        #expect(WhatsNewCatalog.imageURL("menu", language: "it")?.lastPathComponent == "menu.en.jpg")
    }

    @Test("A missing or damaged file gives no content instead of failing")
    func badFiles() throws {
        #expect(WhatsNewCatalog.load(nil).isEmpty)
        let url = FileManager.default.temporaryDirectory.appending(path: "whatsnew-\(UUID().uuidString).json")
        try Data("{\"releases\": [{\"version\": 1}]}".utf8).write(to: url)
        #expect(WhatsNewCatalog.load(url).isEmpty)
        try Data("{\"releases\": [{\"version\": \"0.9.0\", \"pages\": []}]}".utf8).write(to: url)
        #expect(WhatsNewCatalog.load(url).isEmpty)
    }
}

@Suite("What's New languages")
struct WhatsNewLanguageTests {
    static let interface = ["whatsnew.header", "whatsnew.skip", "whatsnew.continue", "whatsnew.start", "whatsnew.soon",
                            "whatsnew.page", "whatsnew.goto"]

    static var keys: [String] {
        interface + WhatsNewCatalog.bundled.flatMap { $0.pages.flatMap { [$0.title, $0.line, $0.alt] } }
    }

    static func lproj(_ language: String) throws -> Bundle {
        try #require(Bundle.module.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)))
    }

    @Test("French and English have every key", arguments: ["fr", "en"])
    func complete(language: String) throws {
        let bundle = try Self.lproj(language)
        for key in Self.keys {
            let value = bundle.localizedString(forKey: key, value: "\u{0}missing", table: WhatsNewText.table)
            #expect(value != "\u{0}missing" && !value.isEmpty && value != key, "\(language) lacks \(key)")
        }
    }

    @Test("A line with a shortcut keeps its placeholder in both languages")
    func placeholders() throws {
        for language in ["fr", "en"] {
            let bundle = try Self.lproj(language)
            for page in WhatsNewCatalog.bundled.flatMap(\.pages) where page.shortcut != nil {
                #expect(bundle.localizedString(forKey: page.line, value: nil, table: WhatsNewText.table).contains("%@"))
            }
        }
    }

    @Test("The French reads as the validated mockup")
    func frenchAsMockup() throws {
        let fr = try Self.lproj("fr")
        func s(_ key: String) -> String { fr.localizedString(forKey: key, value: nil, table: WhatsNewText.table) }
        #expect(s("whatsnew.continue") == "Continuer")
        #expect(s("whatsnew.start") == "Commencer")
        #expect(s("whatsnew.skip") == "Passer")
        #expect(s("whatsnew.soon") == "Bientôt")
        #expect(s("whatsnew.0.2.0.menu.title") == "Menu en jeu")
        #expect(s("whatsnew.0.2.0.upscaling.line") == "Le DLSS passe par MetalFX.")
        #expect(s("whatsnew.0.2.0.framegen.line") == "Jusqu’à 2× plus de FPS.")
        #expect(s("whatsnew.0.2.0.resources.title") == "Apps en arrière-plan")
        #expect(String(localized: "What’s New…", bundle: fr) == "Nouveautés…")
    }

    @Test("The page count reads in the pinned language")
    func pinnedLanguage() {
        WhatsNewText.use(language: "fr")
        #expect(WhatsNewText.string("whatsnew.page", 2, 5) == "2 sur 5")
        WhatsNewText.use(language: "en")
        #expect(WhatsNewText.string("whatsnew.page", 2, 5) == "2 of 5")
        #expect(WhatsNewText.string("whatsnew.header", "0.2.0-beta1") == "What’s New · Cartouche 0.2.0-beta1")
    }
}
