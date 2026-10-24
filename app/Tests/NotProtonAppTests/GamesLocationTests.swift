import Foundation
import Testing

@testable import NotProtonApp

// Every location here is a scratch folder and every slug is unique, so the scan's shared record of where games live
// never meets another suite's games.
@MainActor
@Suite("Games location")
struct GamesLocationTests {

    @MainActor
    private struct Scene {
        let work: URL
        let first: URL
        let second: URL
        let defaults = ScratchDefaults()
        let model: LibraryModel
        let app: URL

        init(_ label: String) throws {
            work = try scratchDirectory("games-location-\(label)")
            first = work.appending(path: "first", directoryHint: .isDirectory)
            second = work.appending(path: "second", directoryHint: .isDirectory)
            app = work.appending(path: "Cartouche.app", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: app.appending(path: "Contents"), withIntermediateDirectories: true)
            // The library starts on a scratch location, never the real one under Application Support
            defaults.defaults.set(first.plainPath, forKey: GameFolder.installsKey)
            model = LibraryModel(store: LibraryStore(folder: work.appending(path: "support")), defaults: defaults.defaults)
        }

        func install(_ name: String, in root: URL) throws -> InstalledGame {
            let folder = try GameFolder.fresh(for: name, in: root)
            let game = InstalledGame(id: folder.root.lastPathComponent, name: name, runnerID: "r",
                                     prefix: folder.prefix.path(percentEncoded: false),
                                     exe: folder.prefix.appending(path: "drive_c/Games/\(name)/game.exe").path(percentEncoded: false),
                                     installedAt: Date(), installerFolder: "/x", redistributables: [])
            try InstalledGames.save(game, in: folder)
            return game
        }

        func remove() { try? FileManager.default.removeItem(at: work) }
    }

    private static func unique(_ name: String) -> String { "\(name) \(UUID().uuidString.prefix(8))" }

    @Test("Changing the location keeps games from the old one in the library, playable where they are")
    func oldGamesStay() async throws {
        let s = try Scene("old-games")
        defer { s.remove() }
        let old = try s.install(Self.unique("Old Game"), in: s.first)
        await s.model.reloadInstalledGames()
        #expect(s.model.games(in: .source(.installer)).map(\.name) == [old.name])

        let moved = Box<URL?>(nil)
        s.model.onGamesLocationChange = { moved.value = $0 }
        #expect(await s.model.changeGamesLocation(to: s.second, app: s.app) == nil)
        #expect(s.model.installsFolder.plainPath == s.second.plainPath)
        #expect(moved.value?.plainPath == s.second.plainPath)
        #expect(s.model.previousInstalls.map(\.plainPath) == [s.first.plainPath])
        #expect(FileManager.default.fileExists(atPath: s.second.path(percentEncoded: false)))

        let new = try s.install(Self.unique("New Game"), in: s.model.installsFolder)
        await s.model.reloadInstalledGames()
        let listed = s.model.games(in: .source(.installer))
        #expect(Set(listed.map(\.name)) == [old.name, new.name])

        // The old game's folder is found where it is, though new installs go to the second location
        let oldGame = try #require(listed.first { $0.name == old.name })
        let folder = try #require(GameFolder.of(oldGame, in: s.model.installsFolder))
        #expect(folder.root.plainPath == s.first.appending(path: old.id).plainPath)
        #expect(folder.isFinished)
        let newGame = try #require(listed.first { $0.name == new.name })
        #expect(GameFolder.of(newGame, in: s.first)?.root.plainPath == s.second.appending(path: new.id).plainPath)

        // A relaunch reads both locations back from the defaults
        let relaunched = LibraryModel(store: LibraryStore(folder: s.work.appending(path: "support")), defaults: s.defaults.defaults)
        #expect(relaunched.installsFolder.plainPath == s.second.plainPath)
        await relaunched.reloadInstalledGames(forgetUnused: true)
        #expect(Set(relaunched.games(in: .source(.installer)).map(\.name)) == [old.name, new.name])
        #expect(relaunched.previousInstalls.map(\.plainPath) == [s.first.plainPath])
    }

    @Test("A new install never takes the slug of a game in an earlier location")
    func slugsStayUnique() async throws {
        let s = try Scene("slugs")
        defer { s.remove() }
        let name = Self.unique("Same Game")
        let old = try s.install(name, in: s.first)
        #expect(await s.model.changeGamesLocation(to: s.second, app: s.app) == nil)
        let folder = try GameFolder.fresh(for: name, in: s.model.installsFolder)
        #expect(folder.root.lastPathComponent == "\(old.id)-2")
    }

    @Test("A game in two locations is listed once, from the current one")
    func duplicateKeepsCurrent() throws {
        let s = try Scene("duplicate")
        defer { s.remove() }
        let name = Self.unique("Twice")
        let old = try s.install(name, in: s.first)
        let current = try s.install(name, in: s.second)
        #expect(old.id == current.id)
        let all = InstalledGames.all(in: s.second, previous: [s.first])
        #expect(all.count == 1)
        #expect(all.first?.prefix == current.prefix)
        #expect(GameFolder.located(current.id)?.plainPath == s.second.plainPath)
    }

    @Test("An earlier location without games is forgotten; one on a disk that is not mounted is kept")
    func forgetsUnused() async throws {
        let s = try Scene("unused")
        defer { s.remove() }
        let empty = s.work.appending(path: "empty", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let deleted = s.work.appending(path: "deleted", directoryHint: .isDirectory)
        let unplugged = URL(filePath: "/Volumes/cartouche-test-\(UUID().uuidString)/Games", directoryHint: .isDirectory)
        _ = try s.install(Self.unique("Kept"), in: s.first)
        #expect(Set(GameFolder.unused([s.first, empty, deleted, unplugged]).map(\.plainPath))
                == [empty.plainPath, deleted.plainPath])

        s.defaults.defaults.set([empty.plainPath, unplugged.plainPath], forKey: GameFolder.previousKey)
        let model = LibraryModel(store: LibraryStore(folder: s.work.appending(path: "support")), defaults: s.defaults.defaults)
        await model.reloadInstalledGames(forgetUnused: true)
        #expect(model.previousInstalls.map(\.plainPath) == [unplugged.plainPath])
        #expect(GameFolder.previous(s.defaults.defaults).map(\.plainPath) == [unplugged.plainPath])
    }

    @Test("Each earlier location is kept once, and the chosen one is never among them")
    func chooseHistory() throws {
        let s = try Scene("history")
        defer { s.remove() }
        let third = s.work.appending(path: "third", directoryHint: .isDirectory)
        let d = s.defaults.defaults
        GameFolder.choose(s.second, leaving: s.first, defaults: d)
        GameFolder.choose(third, leaving: s.second, defaults: d)
        GameFolder.choose(s.second, leaving: third, defaults: d)
        #expect(GameFolder.current(d).plainPath == s.second.plainPath)
        #expect(GameFolder.previous(d).map(\.plainPath) == [s.first.plainPath, third.plainPath])
        #expect(GameFolder.roots(current: s.second, previous: [s.first, s.second, s.first]).map(\.plainPath)
                == [s.second.plainPath, s.first.plainPath])
    }

    @Test("A location inside the app or one that can't be written is refused, and nothing changes")
    func validation() async throws {
        let s = try Scene("validation")
        defer { s.remove() }
        let inside = s.app.appending(path: "Contents/Games", directoryHint: .isDirectory)
        #expect(GameFolder.problem(with: inside, app: s.app) != nil)
        #expect(GameFolder.problem(with: s.app, app: s.app) != nil)
        // Through a link, and for a folder not made yet, it is still inside
        let link = s.work.appending(path: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: s.app.appending(path: "Contents"))
        #expect(GameFolder.problem(with: link.appending(path: "Later/Games"), app: s.app) != nil)
        #expect(!FileManager.default.fileExists(atPath: s.app.appending(path: "Contents/Later").path(percentEncoded: false)))

        let locked = s.work.appending(path: "locked", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path(percentEncoded: false))
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path(percentEncoded: false)) }
        let problem = await s.model.changeGamesLocation(to: locked.appending(path: "Games"), app: s.app)
        #expect(problem == String(localized: "Cartouche can’t write to this folder. Choose another one."))
        #expect(s.model.installsFolder.plainPath == s.first.plainPath)
        #expect(s.model.previousInstalls.isEmpty)
        #expect(GameFolder.current(s.defaults.defaults).plainPath == s.first.plainPath)

        // A new folder is made, and no write check is left behind
        let fresh = s.work.appending(path: "new/Games", directoryHint: .isDirectory)
        #expect(GameFolder.problem(with: fresh, app: s.app) == nil)
        let left = try FileManager.default.contentsOfDirectory(atPath: fresh.path(percentEncoded: false))
        #expect(left.isEmpty)
    }

    @Test("Store games install under a chosen location; with none chosen they stay beside the store's files")
    func storeGames() async throws {
        let s = try Scene("store")
        defer { s.remove() }
        let folder = s.model.storeGameFolder(.epic, title: "Fennec Quest", id: "abc:1")
        #expect(folder?.plainPath == s.first.appending(path: "Store Games/epic/fennec-quest-abc-1").plainPath)

        let unset = ScratchDefaults()
        let fallback = LibraryModel(store: LibraryStore(folder: s.work.appending(path: "support")), defaults: unset.defaults)
        #expect(fallback.storeGameFolder(.epic, title: "Fennec Quest", id: "abc:1") == nil)

        // The store games folder is never read as an installer game
        try FileManager.default.createDirectory(at: try #require(folder), withIntermediateDirectories: true)
        #expect(InstalledGames.all(in: s.first, previous: []).isEmpty)
    }

    @Test("Wine Prefixes and the controller focus check find a game in an earlier location")
    func callersFollow() async throws {
        let s = try Scene("callers")
        defer { s.remove() }
        let old = try s.install(Self.unique("Elsewhere"), in: s.first)
        #expect(await s.model.changeGamesLocation(to: s.second, app: s.app) == nil)
        let game = try #require(s.model.game("installer:\(old.id)"))

        let prefixes = PrefixStore.games(installs: s.second, previous: [s.first],
                                         stores: StoreFolders(root: s.work.appending(path: "stores")))
        #expect(prefixes.contains { $0.appID == old.id })
        #expect(LiveGameFocus.matches(game, environment: ["WINEPREFIX": old.prefix], installs: s.second))
    }

    @Test("Onboarding's games folder takes effect at once, and the library keeps its games")
    func onboardingMoves() async throws {
        let scratch = ScratchDefaults()
        let work = try scratchDirectory("games-location-onboarding")
        defer { try? FileManager.default.removeItem(at: work) }
        let first = work.appending(path: "first", directoryHint: .isDirectory)
        let second = work.appending(path: "second", directoryHint: .isDirectory)
        scratch.defaults.set(first.plainPath, forKey: GameFolder.installsKey)
        let scene = try OnboardingScene("games-location", scratch: scratch)
        defer { scene.remove() }
        #expect(scene.library.installsFolder.plainPath == first.plainPath)
        let model = try scene.model()
        await model.prepare()
        while model.step != .permissions {
            if model.step == .welcome { model.next() } else { model.skip() }
        }
        #expect(model.gamesLocation.plainPath == first.plainPath)
        model.chooseGamesFolder(second)
        model.next()
        #expect(await waitFor(5) { scene.library.installsFolder.plainPath == second.plainPath && !model.movingStorage })
        #expect(model.storageProblem == nil)
        #expect(scene.library.previousInstalls.map(\.plainPath) == [first.plainPath])
        #expect(scratch.defaults.string(forKey: GameFolder.installsKey) == second.plainPath)
    }
}
