import Foundation
import Testing

@testable import NotProtonApp

@Suite("Downloaded Wine Steam loader hooks")
struct WineSteamPatchesTests {
    @Test("Inspected binaries produce the pinned result, keep the original and prepare only once",
          .enabled(if: ProcessInfo.processInfo.environment["CARTOUCHE_TEST_WINE_ROOT"] != nil))
    func realBinaries() throws {
        let source = URL(filePath: try #require(ProcessInfo.processInfo.environment["CARTOUCHE_TEST_WINE_ROOT"]))
        let work = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: work) }
        for entry in WineSteamPatches.entries {
            let file = work.appending(path: entry.path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let original = try Data(contentsOf: Clean.copy(of: source.appending(path: entry.path)))
            #expect(Digest.sha256(of: original) == entry.clean)
            try original.write(to: file)
        }
        let loader = work.appending(path: "bin/wine")
        try FileManager.default.createDirectory(at: loader.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture loader".utf8).write(to: loader)
        var files = Dictionary(uniqueKeysWithValues: WineSteamPatches.entries.map { ($0.path, $0.clean) })
        files["bin/wine"] = try Digest.sha256(of: loader)
        let receipt = WineRunnerInstaller.Receipt(id: work.lastPathComponent, archiveSHA256: "fixture", files: files, loader: "bin/wine")
        try JSONEncoder().encode(receipt).write(to: work.appending(path: WineRunnerInstaller.receiptName))
        #expect(WineSteamPatches.needsPreparation(work))
        #expect(try WineSteamPatches.install(in: work).count == 2)
        #expect(!WineSteamPatches.needsPreparation(work))
        for entry in WineSteamPatches.entries {
            let file = work.appending(path: entry.path)
            #expect(Digest.sha256IfPresent(file) == entry.patched)
            #expect(Digest.sha256IfPresent(Clean.copy(of: file)) == entry.clean)
        }
        #expect(try WineSteamPatches.install(in: work).isEmpty)
        try WineRunnerInstaller.recordPreparedLoader(work.lastPathComponent, runners: work.deletingLastPathComponent())
        #expect(WineRunnerInstaller.verify(work.lastPathComponent, runners: work.deletingLastPathComponent()).isEmpty)
    }

    @Test("An unknown or damaged binary is never patched with another build's offsets")
    func unknownBinary() throws {
        let work = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: work) }
        let file = work.appending(path: WineSteamPatches.entries[0].path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("unknown Wine binary".utf8)
        try original.write(to: file)
        #expect(try WineSteamPatches.install(in: work).isEmpty)
        #expect(try Data(contentsOf: file) == original)
    }
}
