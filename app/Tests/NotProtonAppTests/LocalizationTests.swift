import Foundation
import Testing

@testable import NotProtonApp

@Suite("Localization")
struct LocalizationTests {
    let chinese = Bundle.module.path(forResource: "zh-Hans", ofType: "lproj").flatMap(Bundle.init(path:))

    @Test("Chinese text is looked up with interpolated values in place")
    func chineseLookup() throws {
        let zh = try #require(chinese)
        #expect(String(localized: "Ready", bundle: zh) == "就绪")
        #expect(String(localized: "Delete \(3) prefixes?", bundle: zh) == "删除 3 个游戏容器？")
    }

    @Test("Chinese text can put interpolated values in another order")
    func chineseReorders() throws {
        let zh = try #require(chinese)
        #expect(String(localized: "Opened \("Wine Configuration") in \("Zuma Deluxe").", bundle: zh)
            == "已在“Zuma Deluxe”中打开Wine Configuration。")
    }

    let italian = Bundle.module.path(forResource: "it", ofType: "lproj").flatMap(Bundle.init(path:))

    @Test("Italian text is looked up with interpolated values in place")
    func italianLookup() throws {
        let it = try #require(italian)
        #expect(String(localized: "Ready", bundle: it) == "Pronto")
        #expect(String(localized: "Delete \(3) prefixes?", bundle: it) == "Eliminare 3 prefissi?")
        #expect(String(localized: "Opened \("Wine Configuration") in \("Zuma Deluxe").", bundle: it)
            == "Aperto Wine Configuration in Zuma Deluxe.")
    }

    @Test("A string not yet translated into one language shows English there")
    func pendingTranslationFallsBack() throws {
        let zh = try #require(chinese)
        let it = try #require(italian)
        #expect(String(localized: "The trial version is not supported.", bundle: zh) == "不支持试用版。")
        #expect(zh.localizedString(forKey: "Not in any table yet", value: nil, table: nil) == "Not in any table yet")
        #expect(String(localized: "The trial version is not supported.", bundle: it)
            == "La versione di prova non è supportata.")
    }

    @Test("The session and rename strings read in Chinese and Italian")
    func sessionStrings() throws {
        let zh = try #require(chinese)
        let it = try #require(italian)
        #expect(String(localized: "End Wine Session", bundle: zh) == "结束 Wine 会话")
        #expect(String(localized: "Identified as \("Hollow Knight")?", bundle: zh) == "识别为 Hollow Knight？")
        #expect(String(localized: "End Wine Session", bundle: it) == "Termina sessione Wine")
        #expect(String(localized: "Rename…", bundle: it) == "Rinomina…")
    }

    @Test("The About copy and the MacGamingDB terms read in each language")
    func creditsTranslated() throws {
        let it = try #require(italian)
        let zh = try #require(chinese)
        let french = try #require(Bundle.module.path(forResource: "fr", ofType: "lproj").flatMap(Bundle.init(path:)))
        let credits = Attribution.credits(in: it)
        #expect(credits.hasPrefix("I tuoi giochi. Il tuo Mac."))
        #expect(credits.hasSuffix("Sito web · GitHub"))
        #expect(Attribution.credits(in: zh).contains("免费且开源。"))
        #expect(Attribution.credits(in: french).contains("Vos jeux. Votre Mac."))
        #expect(String(localized: "No data license published", bundle: french) == "Aucune licence de données publiée")
        #expect(String(localized: "Applications has Cartouche \("0.2.0 (9)"). This copy is \("0.1.0 (5)"). Moving it would replace the newer version.",
                       bundle: it)
            == "In Applicazioni c’è Cartouche 0.2.0 (9). Questa copia è la 0.1.0 (5). Spostarla sostituirebbe la versione più recente.")
    }
}
