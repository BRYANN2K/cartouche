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
        #expect(String(localized: "The trial version is not supported.", bundle: zh)
            == "The trial version is not supported.")
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
}
