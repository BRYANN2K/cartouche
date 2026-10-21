import Foundation
import InstallerKit
import Testing

@testable import NotProtonApp

// Entries served from memory; extract writes them as files so the staging,
// move and follow-up classification run for real.
private struct FakeEngine: ArchiveEngine {
    var entries: [ArchiveEntry]
    var failure: ArchiveError?
    var hold = false
    var entered: Flag?

    func probe(_ volumes: [URL]) throws -> ArchiveProbe {
        if let failure { throw failure }
        return ArchiveProbe(
            format: .zip, formatName: "fake", filters: [], entries: entries,
            hasEncryptedEntries: entries.contains { $0.isEncrypted },
            uncompressedSize: entries.filter { $0.kind == .file }.reduce(0) { $0 + $1.size })
    }

    func extract(_ volumes: [URL],
                 route: @Sendable (ArchiveEntry) throws -> EntryDestination,
                 bytesDone: @Sendable (Int64) -> Void,
                 isCancelled: @Sendable () -> Bool) throws {
        entered?.set()
        if hold {
            while !isCancelled() { Thread.sleep(forTimeInterval: 0.001) }
            throw CancellationError()
        }
        if let failure { throw failure }
        var written: Int64 = 0
        for entry in entries {
            if isCancelled() { throw CancellationError() }
            guard case .write(let dest) = try route(entry) else { continue }
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            if entry.kind == .directory {
                try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            } else {
                try Data("x".utf8).write(to: dest)
                written += entry.size
                bytesDone(written)
            }
        }
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    func check() -> Bool { lock.withLock { value } }
}

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [DropProgress] = []
    func add(_ p: DropProgress) { lock.withLock { values.append(p) } }
    func all() -> [DropProgress] { lock.withLock { values } }
}

private struct StalledClassifier: DropClassifying {
    func classify(_ urls: [URL], progress: @escaping @Sendable (DropProgress) -> Void) async throws -> DropResult {
        try await Task.sleep(for: .seconds(60))
        return DropFixtures.roms
    }
}

private func folder(_ label: String, _ files: [String: Data] = [:]) throws -> URL {
    let dir = try scratchDirectory(label)
    for (name, content) in files {
        let url = dir.appending(path: name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try content.write(to: url)
    }
    return dir
}

private func nes() -> Data { Data("NES\u{1A}".utf8) + Data(count: 100) }

// A Unity game folder, the recipe the installed-game detector recognizes.
private func gameFolderTree(_ label: String) throws -> URL {
    let dir = try folder(label, [
        "UnityPlayer.dll": Data(),
        "Game_Data/Plugins/x86_64/steam_api64.dll": Data(),
    ])
    let exe = dir.appending(path: "Game.exe")
    FileManager.default.createFile(atPath: exe.path, contents: Data("MZ".utf8))
    try FileHandle(forWritingTo: exe).truncate(atOffset: 1 << 20)
    return dir
}

private func adapter(_ workspace: URL, engine: FakeEngine? = nil) -> InstallerKitDropClassifier {
    InstallerKitDropClassifier(workspace: workspace) {
        engine.map { ArchiveExtractor(engine: $0, freeBytes: { _ in Int64.max / 4 }) }
    }
}

@MainActor
@Suite("Drop adapter", .serialized)
struct DropAdapterTests {

    // MARK: mapping

    @Test func mapsEveryFailure() {
        let url = URL(filePath: "/tmp/game.rar")
        #expect(InstallerKitDropClassifier.map(.passwordProtected(url)) == .passwordProtected(url))
        #expect(InstallerKitDropClassifier.map(.unsupportedArchive(url)) == .unsupportedArchive(url))
        #expect(InstallerKitDropClassifier.map(.damagedArchive(url)) == .damagedArchive(url))
        #expect(InstallerKitDropClassifier.map(.missingVolume(url, "game.part2.rar"))
                == .missingVolume(url, "game.part2.rar"))
        #expect(InstallerKitDropClassifier.map(.insufficientSpace(url, needed: 9, available: 4))
                == .insufficientSpace(url, needed: 9, free: 4))
        #expect(InstallerKitDropClassifier.map(.nothingRecognized([url])) == .nothingRecognized([url]))
    }

    @Test func missingVolumeNamesThePart() async throws {
        let src = try folder("mv-src", ["g.part1.rar": Data("x".utf8), "g.part3.rar": Data("x".utf8)])
        let dst = try scratchDirectory("mv-dst")
        let result = try await adapter(dst, engine: FakeEngine(entries: []))
            .classify([src.appending(path: "g.part1.rar")]) { _ in }
        // The volume URL comes back from directory enumeration, which returns
        // realpaths (/var → /private/var).
        let enumerated = try FileManager.default.contentsOfDirectory(
            at: src, includingPropertiesForKeys: nil).first { $0.lastPathComponent == "g.part1.rar" }
        #expect(result == .failed(.missingVolume(try #require(enumerated), "g.part2.rar")))
    }

    @Test func insufficientSpaceCarriesTheNumbers() async throws {
        let src = try folder("space-src", ["game.7z": Data("x".utf8)])
        let dst = try scratchDirectory("space-dst")
        let result = try await adapter(dst, engine: FakeEngine(
            entries: [], failure: .insufficientSpace(needed: 60_000_000_000, available: 8_000_000_000)))
            .classify([src.appending(path: "game.7z")]) { _ in }
        #expect(result == .failed(.insufficientSpace(src.appending(path: "game.7z"),
                                                     needed: 60_000_000_000, free: 8_000_000_000)))
    }

    @Test func passwordProtectedAndDamaged() async throws {
        let src = try folder("fail-src", ["locked.zip": Data("x".utf8), "bad.zip": Data("x".utf8)])
        let dst = try scratchDirectory("fail-dst")
        let locked = try await adapter(dst, engine: FakeEngine(entries: [], failure: .passwordProtected))
            .classify([src.appending(path: "locked.zip")]) { _ in }
        #expect(locked == .failed(.passwordProtected(src.appending(path: "locked.zip"))))
        let bad = try await adapter(dst, engine: FakeEngine(entries: [], failure: .damaged("eof")))
            .classify([src.appending(path: "bad.zip")]) { _ in }
        #expect(bad == .failed(.damagedArchive(src.appending(path: "bad.zip"))))
    }

    // MARK: missing dylib

    @Test("No dylib: archives report detection unavailable, folders still classify")
    func missingDylib() async throws {
        let src = try folder("no-engine-src", ["game.rar": Data("x".utf8)])
        let game = try gameFolderTree("no-engine-game")
        let dst = try scratchDirectory("no-engine-dst")
        let classifier = adapter(dst)  // engine() resolves to nil
        let archive = try await classifier.classify([src.appending(path: "game.rar")]) { _ in }
        #expect(archive == .failed(.detectionUnavailable))
        let folder = try await classifier.classify([game]) { _ in }
        guard case .installedGame = folder else { Issue.record("got \(folder)"); return }
    }

    // MARK: routing

    @Test func installerFolder() async throws {
        let dir = try folder("installer", [
            "setup_game.exe": Data(("MZ" + String(repeating: "x", count: 100)).utf8),
            "data-01.bin": Data("a".utf8), "data-02.bin": Data("b".utf8),
        ])
        let dst = try scratchDirectory("installer-dst")
        let result = try await adapter(dst).classify([dir]) { _ in }
        guard case .installer(let i) = result else { Issue.record("got \(result)"); return }
        #expect(i.setup.lastPathComponent == "setup_game.exe")
        #expect(i.parts == 2)
    }

    @Test func installedGameFolder() async throws {
        let dir = try gameFolderTree("game")
        let dst = try scratchDirectory("game-dst")
        let result = try await adapter(dst).classify([dir]) { _ in }
        guard case .installedGame(let g) = result else { Issue.record("got \(result)"); return }
        #expect(g.folder.standardizedFileURL == dir.standardizedFileURL)
        #expect(g.executables.map { $0.lastPathComponent } == ["Game.exe"])
        #expect(!g.name.isEmpty)
    }

    @Test func romFilesAndMixed() async throws {
        let dir = try folder("roms", ["contra.nes": nes()])
        let game = try gameFolderTree("mixed-game")
        let dst = try scratchDirectory("roms-dst")
        let rom = try await adapter(dst).classify([dir.appending(path: "contra.nes")]) { _ in }
        guard case .roms(let r) = rom else { Issue.record("got \(rom)"); return }
        #expect(r.groups.map(\.console) == ["nes"])
        let mixed = try await adapter(dst).classify([game, dir.appending(path: "contra.nes")]) { _ in }
        guard case .mixed(let parts) = mixed else { Issue.record("got \(mixed)"); return }
        #expect(parts.count == 2)
        #expect(parts.contains { if case .installedGame = $0 { true } else { false } })
        #expect(parts.contains { if case .roms = $0 { true } else { false } })
    }

    @Test func nothingRecognized() async throws {
        let dir = try folder("nothing", ["notes.docx": Data("x".utf8)])
        let dst = try scratchDirectory("nothing-dst")
        let result = try await adapter(dst).classify([dir.appending(path: "notes.docx")]) { _ in }
        #expect(result == .failed(.nothingRecognized([dir.appending(path: "notes.docx")])))
    }

    // MARK: archives extract, then classify

    @Test func archiveExtractsThenClassifiesWithProgress() async throws {
        let src = try folder("zip-src", ["game.zip": Data("x".utf8)])
        let dst = try scratchDirectory("zip-dst")
        let engine = FakeEngine(entries: [
            ArchiveEntry(path: "setup_game.exe", size: 10, kind: .file),
            ArchiveEntry(path: "data-01.bin", size: 5, kind: .file),
            ArchiveEntry(path: "data-02.bin", size: 5, kind: .file),
        ])
        let log = ProgressLog()
        let zip = src.appending(path: "game.zip")
        let result = try await adapter(dst, engine: engine).classify([zip]) { log.add($0) }
        guard case .installer(let i) = result else { Issue.record("got \(result)"); return }
        #expect(i.setup.lastPathComponent == "setup_game.exe")
        // The extracted folder landed in the workspace, where imports read it.
        #expect(i.setup.path(percentEncoded: false).hasPrefix(dst.path(percentEncoded: false)))
        // Progress moved from ArchiveProgress to DropProgress.
        #expect(log.all().last?.bytesDone == 20)
        // No staging folder is left behind.
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: dst.path)) ?? []
        #expect(!leftovers.contains { $0.hasPrefix(".cartouche-drop-") })
    }

    @Test func zipOfRomsStaysZipped() async throws {
        let src = try folder("romzip-src", ["roms.zip": Data("x".utf8)])
        let dst = try scratchDirectory("romzip-dst")
        let engine = FakeEngine(entries: [
            ArchiveEntry(path: "a.sfc", size: 4, kind: .file),
            ArchiveEntry(path: "b.sfc", size: 4, kind: .file),
            ArchiveEntry(path: "readme.txt", size: 4, kind: .file),
        ])
        let zip = src.appending(path: "roms.zip")
        let result = try await adapter(dst, engine: engine).classify([zip]) { _ in }
        #expect(result == .roms(DroppedROMs(
            groups: [DroppedConsoleGroup(console: "snes", files: [zip])], unknown: [])))
    }

    // MARK: cancel

    @Test func cancelDuringExtractionCleansUp() async throws {
        let src = try folder("cancel-src", ["game.zip": Data("x".utf8)])
        let dst = try scratchDirectory("cancel-dst")
        let entered = Flag()
        let engine = FakeEngine(entries: [ArchiveEntry(path: "f", size: 1, kind: .file)],
                                hold: true, entered: entered)
        let zip = src.appending(path: "game.zip")
        let task = Task { try await adapter(dst, engine: engine).classify([zip]) { _ in } }
        for _ in 0 ..< 2_000 where !entered.check() { try await Task.sleep(for: .milliseconds(1)) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        // The cancelled staging is removed; the source archive stays.
        #expect((try? FileManager.default.contentsOfDirectory(atPath: dst.path))?.isEmpty == true)
        #expect(FileManager.default.fileExists(atPath: zip.path))
    }

    @Test func modelCancelClosesTheSheet() async throws {
        let model = DropModel(classifier: StalledClassifier())
        model.start([URL(filePath: "/tmp/anything.zip")])
        guard case .detecting = model.phase else { Issue.record("not detecting"); return }
        model.cancel()
        #expect(model.phase == nil)
        #expect(!model.isPresented)
    }
}
