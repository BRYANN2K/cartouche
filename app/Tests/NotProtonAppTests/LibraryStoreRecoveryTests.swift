import Foundation
import Testing
@testable import NotProtonApp

@Suite("library.json survives fields it doesn't know")
struct LibraryStoreRecoveryTests {

    @Test("An unknown backend or a missing field only resets that field; favorites, covers and other setups stay")
    func unknownValuesKeepTheRest() throws {
        let work = try scratchDirectory("library-lenient")
        defer { try? FileManager.default.removeItem(at: work) }
        let store = LibraryStore(folder: work)
        let json = #"""
        {"favorites":["steam:730"],"covers":{"steam:730":"a.png"},
         "setups":{"steam:730":{"graphics":"vulkan9","translation":"fex","metalHUD":"yes",
                                "advanced":{"msync":true,"dlss":"maybe"}},
                   "steam:570":{"version":"linux","runnerID":"26.3.0.39832"},
                   "steam:10":"garbage"}}
        """#
        try Data(json.utf8).write(to: store.file)
        let choices = store.load()
        #expect(choices.favorites == ["steam:730"])
        #expect(choices.hidden.isEmpty)
        #expect(choices.covers == ["steam:730": "a.png"])
        let cs = try #require(choices.setups["steam:730"])
        #expect(cs.graphics == nil && cs.translation == .fex && cs.metalHUD == nil)
        #expect(cs.advanced == AdvancedGameOptions(msync: true))
        #expect(choices.setups["steam:570"] == GameSetupChoice(runnerID: "26.3.0.39832"))
        #expect(choices.setups["steam:10"] == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: work.path(percentEncoded: false)) == ["library.json"])
    }

    @Test("A file that isn't JSON moves aside before the next save can overwrite it")
    func unreadableFileIsQuarantined() throws {
        let work = try scratchDirectory("library-quarantine")
        defer { try? FileManager.default.removeItem(at: work) }
        let store = LibraryStore(folder: work)
        try Data(#"{"favorites":["steam:730"#.utf8).write(to: store.file)
        #expect(store.load() == LibraryChoices())
        var choices = LibraryChoices(); choices.favorites = ["steam:1"]
        try store.save(choices)
        let names = try FileManager.default.contentsOfDirectory(atPath: work.path(percentEncoded: false))
        let bad = try #require(names.first { $0.hasPrefix("library.json.bad-") })
        #expect(try String(contentsOf: work.appending(path: bad), encoding: .utf8) == #"{"favorites":["steam:730"#)
        #expect(store.load() == choices)
    }

    @Test("Quarantine never overwrites an earlier quarantined copy; an absent file isn't quarantined")
    func quarantineNames() throws {
        let work = try scratchDirectory("json-quarantine")
        defer { try? FileManager.default.removeItem(at: work) }
        let file = work.appending(path: "controls.json")
        let now = Date(timeIntervalSince1970: 1_000)
        #expect(JSONFile.load([String: Int].self, from: file, now: now) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: work.path(percentEncoded: false)).isEmpty)
        try Data("one".utf8).write(to: file)
        #expect(JSONFile.load([String: Int].self, from: file, now: now) == nil)
        try Data("two".utf8).write(to: file)
        #expect(JSONFile.load([String: Int].self, from: file, now: now) == nil)
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: work.path(percentEncoded: false)))
        #expect(names == ["controls.json.bad-1000", "controls.json.bad-1000-1"])
    }
}
