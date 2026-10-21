import Foundation
import Testing

@testable import RetroArchKit

// Cores from a local server playing the buildbot
@Suite("Cores and consoles", .serialized)
struct CoreManagerTests {

    final class Buildbot {
        let server: FixtureServer
        let base: URL
        let work: URL
        let paths: RetroArchPaths
        let cores: CoreManager

        init() async throws {
            work = try scratchFolder("cores")
            server = try FixtureServer()
            base = try await server.start()
            paths = RetroArchPaths(root: work.appending(path: "cartouche"))
            let source = CoreSource(cores: base.appending(path: "nightly/"), info: base.appending(path: "info.zip"))
            let bin = work.appending(path: "bin", directoryHint: .isDirectory)
            // The Trash in a test moves into the scene's own bin/, never the user's real Trash
            cores = CoreManager(paths: paths, source: source, session: URLSession(configuration: .ephemeral)) { url in
                try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: url, to: bin.appending(path: url.lastPathComponent))
            }
            try serve("snes9x", build: "1")
            try serve("sameboy", build: "1")
            try serve("swanstation", build: "1")
            let infos = try ["snes9x", "sameboy", "swanstation"].reduce(into: [String: Data]()) { all, core in
                all["\(core)_libretro.info"] = try Data(contentsOf: Fixtures.url("info/\(core)_libretro.info"))
            }
            server.put("/info.zip", try zipFixture(infos, in: work))
        }

        func serve(_ core: String, build: String) throws {
            server.put("/nightly/\(core)_libretro.dylib.zip", try zipFixture(["\(core)_libretro.dylib": fakeCore(build)], in: work))
        }

        var coresFolder: [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: paths.cores.path)) ?? []).sorted()
        }

        deinit { server.stop() }
    }

    @Test func installDownloadsVerifiesAndRecords() async throws {
        let bot = try await Buildbot()
        let record = try await bot.cores.install("snes9x")

        #expect(bot.coresFolder == ["snes9x_libretro.dylib"])
        let file = await bot.cores.url("snes9x")
        #expect(record.sha256 == (try CoreManager.sha256(file)))
        #expect(record.size == Int64(fakeCore("1").count))
        #expect(record.source.absoluteString.hasSuffix("/nightly/snes9x_libretro.dylib.zip"))
        #expect(await bot.cores.check("snes9x") == .verified)
        #expect(FileManager.default.fileExists(atPath: bot.paths.coreInfo.appending(path: "snes9x_libretro.info").path))
        #expect(bot.server.requests == ["/nightly/snes9x_libretro.dylib.zip", "/info.zip"])
    }

    @Test func aCoreHereAsRecordedIsNotDownloadedAgain() async throws {
        let bot = try await Buildbot()
        try await bot.cores.install("snes9x")
        try await bot.cores.install("snes9x")
        #expect(bot.server.requests.filter { $0.hasSuffix(".dylib.zip") }.count == 1)
    }

    @Test func aChangedCoreIsCaughtAtLaunch() async throws {
        let bot = try await Buildbot()
        try await bot.cores.install("snes9x")
        #expect(try await bot.cores.ready("snes9x") == bot.cores.url("snes9x"))

        let file = await bot.cores.url("snes9x")
        try (fakeCore("1") + Data("patched".utf8)).write(to: file)
        #expect(await bot.cores.check("snes9x") == .changed)
        await #expect(throws: CoreError.damaged(core: "snes9x")) { try await bot.cores.ready("snes9x") }
    }

    @Test func updateRecordsTheNewBuild() async throws {
        let bot = try await Buildbot()
        let first = try await bot.cores.install("snes9x")
        try bot.serve("snes9x", build: "2")
        let second = try await bot.cores.update("snes9x")
        #expect(first.sha256 != second.sha256)
        #expect(await bot.cores.record("snes9x") == second)
        #expect(await bot.cores.check("snes9x") == .verified)
        #expect(try Data(contentsOf: bot.cores.url("snes9x")) == fakeCore("2"))
    }

    @Test func aFailedUpdateKeepsTheCoreThatWorks() async throws {
        let bot = try await Buildbot()
        try await bot.cores.install("snes9x")
        bot.server.fail("/nightly/snes9x_libretro.dylib.zip", with: 503)
        do {
            try await bot.cores.update("snes9x")
            Issue.record("the update did not fail")
        } catch let error as CoreError {
            #expect(error.localizedDescription == "Core download failed, try again later.")
        }
        #expect(await bot.cores.check("snes9x") == .verified)
        #expect(try Data(contentsOf: bot.cores.url("snes9x")) == fakeCore("1"))
    }

    @Test func somethingThatIsNotACoreIsRefused() async throws {
        let bot = try await Buildbot()
        bot.server.put("/nightly/snes9x_libretro.dylib.zip", try zipFixture(["snes9x_libretro.dylib": Data("<html>".utf8)], in: bot.work))
        await #expect(throws: CoreError.notACore(core: "snes9x")) { try await bot.cores.install("snes9x") }
        bot.server.put("/nightly/snes9x_libretro.dylib.zip", try zipFixture(["readme.txt": Data("hi".utf8)], in: bot.work))
        await #expect(throws: CoreError.notACore(core: "snes9x")) { try await bot.cores.install("snes9x") }
        #expect(bot.coresFolder.isEmpty)
        #expect(await bot.cores.records().isEmpty)
    }

    @Test func deleteRemovesTheFileAndItsRecord() async throws {
        let bot = try await Buildbot()
        try await bot.cores.install("snes9x")
        try await bot.cores.delete("snes9x")
        #expect(bot.coresFolder.isEmpty)
        #expect(await bot.cores.record("snes9x") == nil)
        #expect(await bot.cores.check("snes9x") == .missing)
    }

    @Test func addingSuperNintendoDownloadsOnlySnes9x() async throws {
        let bot = try await Buildbot()
        let shelf = ConsoleShelf(paths: bot.paths, cores: bot.cores)
        try await shelf.add("snes")

        #expect(bot.coresFolder == ["snes9x_libretro.dylib"])
        #expect(bot.server.requests.filter { $0.hasSuffix(".dylib.zip") } == ["/nightly/snes9x_libretro.dylib.zip"])
        #expect(await shelf.added().map(\.id) == ["snes"])
    }

    @Test func removingSuperNintendoDeletesItsCoreAndNoGame() async throws {
        let bot = try await Buildbot()
        let shelf = ConsoleShelf(paths: bot.paths, cores: bot.cores)
        let games = bot.work.appending(path: "Games", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: games, withIntermediateDirectories: true)
        let files = [
            games.appending(path: "Test Cart.sfc"), games.appending(path: "Other.smc"),
            bot.paths.root.appending(path: "Test Cart.sfc"),
        ]
        try await shelf.add("snes")
        for (i, file) in files.enumerated() { try Data("game \(i)".utf8).write(to: file) }
        let before = try files.map { try CoreManager.sha256($0) }

        try await shelf.remove("snes")

        #expect(bot.coresFolder.isEmpty)
        #expect(await shelf.added().isEmpty)
        #expect(try files.map { try CoreManager.sha256($0) } == before)
    }

    @Test func aSharedCoreStaysWhileAConsoleStillUsesIt() async throws {
        let bot = try await Buildbot()
        let shelf = ConsoleShelf(paths: bot.paths, cores: bot.cores)
        try await shelf.add("gb")
        try await shelf.add("gbc")
        try await shelf.remove("gb")
        #expect(bot.coresFolder == ["sameboy_libretro.dylib"])
        try await shelf.remove("gbc")
        #expect(bot.coresFolder.isEmpty)
    }

    @Test func everyConsoleHasOneRecommendedCore() {
        let ids = ConsoleCatalog.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(ConsoleCatalog.console("snes")?.core == "snes9x")
        #expect(ConsoleCatalog.console("ps1")?.core == "swanstation")
    }
}
