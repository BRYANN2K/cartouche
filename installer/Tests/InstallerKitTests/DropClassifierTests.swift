import Foundation
import Testing
@testable import InstallerKit

private struct FakeEngine: ArchiveEngine {
    var probeResult: ArchiveProbe
    var failure: ArchiveError?
    func probe(_ volumes: [URL]) throws -> ArchiveProbe {
        if let failure { throw failure }
        return probeResult
    }
    func extract(_ volumes: [URL],
                 route: @Sendable (ArchiveEntry) throws -> EntryDestination,
                 bytesDone: @Sendable (Int64) -> Void,
                 isCancelled: @Sendable () -> Bool) throws {
        if let failure { throw failure }
        for entry in probeResult.entries {
            if isCancelled() { throw CancellationError() }
            guard case .write(let dest) = try route(entry) else { continue }
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            if entry.kind == .directory { try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true) }
            else {
                try Data("x".utf8).write(to: dest)
                bytesDone(entry.size)
            }
        }
    }
}

private func probe(_ paths: [(String, ArchiveEntry.Kind)], encrypted: Bool = false,
                   format: ArchiveFormat = .zip) -> ArchiveProbe {
    ArchiveProbe(format: format, formatName: "fake", filters: [],
                 entries: paths.map { ArchiveEntry(path: $0.0, size: 4, kind: $0.1, linkTarget: nil) },
                 hasEncryptedEntries: encrypted,
                 uncompressedSize: Int64(paths.filter { $0.1 == .file }.count * 4))
}

private func classifier(probe p: ArchiveProbe, workspace: URL) -> DropClassifier {
    DropClassifier(extractor: ArchiveExtractor(engine: FakeEngine(probeResult: p),
            freeBytes: { _ in Int64.max / 4 }), workspace: workspace)
}

// Minimal console headers: iNES and Game Boy are the two with real magic.
private func nes() -> Data { Data("NES\u{1A}".utf8) + Data(count: 100) }

private func gameboy(flag: UInt8 = 0x00) -> Data {
    var data = Data(count: 0x150)
    let logo: [UInt8] = [
        0xCE, 0xED, 0x66, 0x66, 0xCC, 0x0D, 0x00, 0x0B, 0x03, 0x73, 0x00, 0x83,
        0x00, 0x0C, 0x00, 0x0D, 0x00, 0x08, 0x11, 0x1F, 0x88, 0x89, 0x00, 0x0E,
        0xDC, 0xCC, 0x6E, 0xE6, 0xDD, 0xDD, 0xD9, 0x99, 0xBB, 0xBB, 0x67, 0x63,
        0x6E, 0x0E, 0xEC, 0xCC, 0xDD, 0xDC, 0x99, 0x9F, 0xBB, 0xB9, 0x33, 0x3E,
    ]
    data.replaceSubrange(0x104 ..< 0x104 + logo.count, with: logo)
    data[0x143] = flag
    return data
}

// A GBA cart carries its own 156-byte logo at 0x04, not the Game Boy one.
private func gba() -> Data {
    var data = Data(count: 0x200)
    let logo: [UInt8] = [
        0x24, 0xFF, 0xAE, 0x51, 0x69, 0x9A, 0xA2, 0x21, 0x3D, 0x84, 0x82, 0x0A,
        0x84, 0xE4, 0x09, 0xAD, 0x11, 0x24, 0x8B, 0x98, 0xC0, 0x81, 0x7F, 0x21,
        0xA3, 0x52, 0xBE, 0x19, 0x93, 0x09, 0xCE, 0x20, 0x10, 0x46, 0x4A, 0x4A,
        0xF8, 0x27, 0x31, 0xEC, 0x58, 0xC7, 0xE8, 0x33, 0x82, 0xE3, 0xCE, 0xBF,
        0x85, 0xF4, 0xDF, 0x94, 0xCE, 0x4B, 0x09, 0xC1, 0x94, 0x56, 0x8A, 0xC0,
        0x13, 0x72, 0xA7, 0xFC, 0x9F, 0x84, 0x4D, 0x73, 0xA3, 0xCA, 0x9A, 0x61,
        0x58, 0x97, 0xA3, 0x27, 0xFC, 0x03, 0x98, 0x76, 0x23, 0x1D, 0xC7, 0x61,
        0x03, 0x04, 0xAE, 0x56, 0xBF, 0x38, 0x84, 0x00, 0x40, 0xA7, 0x0E, 0xFD,
        0xFF, 0x52, 0xFE, 0x03, 0x6F, 0x95, 0x30, 0xF1, 0x97, 0xFB, 0xC0, 0x85,
        0x60, 0xD6, 0x80, 0x25, 0xA9, 0x63, 0xBE, 0x03, 0x01, 0x4E, 0x38, 0xE2,
        0xF9, 0xA2, 0x34, 0xFF, 0xBB, 0x3E, 0x03, 0x44, 0x78, 0x00, 0x90, 0xCB,
        0x88, 0x11, 0x3A, 0x94, 0x65, 0xC0, 0x7C, 0x63, 0x87, 0xF0, 0x3C, 0xAF,
        0xD6, 0x25, 0xE4, 0x8B, 0x38, 0x0A, 0xAC, 0x72, 0x21, 0xD4, 0xF8, 0x07,
    ]
    data.replaceSubrange(0x04 ..< 0x04 + logo.count, with: logo)
    return data
}

@Suite("Drop classifier")
struct DropClassifierTests {

    // MARK: installers and games

    @Test func setupWithPartsIsAnInstaller() async throws {
        let dir = try tempFolder(["setup_game.exe": "MZ" + String(repeating: "x", count: 100),
                                  "data-01.bin": "a", "data-02.bin": "b"])
        let outcome = try await DropClassifier().classify([dir])
        guard case .installer(let i) = outcome else { Issue.record("got \(outcome)"); return }
        #expect(i.setup.lastPathComponent == "setup_game.exe")
        #expect(i.parts == 2)
    }

    private static func gameFolder() throws -> URL {
        let dir = try tempFolder(["UnityPlayer.dll": "", "Game_Data/Plugins/x86_64/steam_api64.dll": ""])
        let exe = dir.appending(path: "Game.exe")
        FileManager.default.createFile(atPath: exe.path, contents: Data("MZ".utf8))
        try FileHandle(forWritingTo: exe).truncate(atOffset: 1 << 20)
        return dir
    }

    @Test func unityFolderIsAnInstalledGame() async throws {
        let dir = try Self.gameFolder()
        let outcome = try await DropClassifier().classify([dir])
        guard case .installedGame(let g) = outcome else { Issue.record("got \(outcome)"); return }
        #expect(g.folder == dir)
        #expect(!g.name.isEmpty)
        #expect(g.executables.map(\.lastPathComponent) == ["Game.exe"])
    }

    @Test func aGameExeAloneResolvesToItsFolder() async throws {
        let dir = try Self.gameFolder()
        let outcome = try await DropClassifier().classify([dir.appending(path: "Game.exe")])
        guard case .installedGame(let g) = outcome else { Issue.record("got \(outcome)"); return }
        #expect(g.folder == dir)
    }

    // MARK: ROMs

    @Test func romFilesGroupByConsole() async throws {
        let dir = try tempFolder([:])
        try nes().write(to: dir.appending(path: "contra.nes"))
        try gameboy().write(to: dir.appending(path: "tetris.gb"))
        try gameboy(flag: 0xC0).write(to: dir.appending(path: "oracle.gbc"))
        try gba().write(to: dir.appending(path: "fusion.gba"))
        let outcome = try await DropClassifier().classify([
            dir.appending(path: "contra.nes"),
            dir.appending(path: "tetris.gb"),
            dir.appending(path: "oracle.gbc"),
            dir.appending(path: "fusion.gba"),
        ])
        guard case .roms(let r) = outcome else { Issue.record("got \(outcome)"); return }
        #expect(r.groups.map(\.console) == ["gb", "gba", "gbc", "nes"])
    }

    @Test func extensionOnlyConsole() async throws {
        let dir = try tempFolder([:])
        try Data(count: 100).write(to: dir.appending(path: "chrono.sfc"))
        let outcome = try await DropClassifier().classify([dir.appending(path: "chrono.sfc")])
        guard case .roms(let r) = outcome else { Issue.record("got \(outcome)"); return }
        #expect(r.groups.first?.console == "snes")
    }

    @Test func wrongMagicIsNotARom() async throws {
        let dir = try tempFolder([:])
        try Data("not a rom".utf8).write(to: dir.appending(path: "fake.nes"))
        try Data("not a rom".utf8).write(to: dir.appending(path: "fake.gba"))
        let outcome = try await DropClassifier().classify([
            dir.appending(path: "fake.nes"), dir.appending(path: "fake.gba")])
        switch outcome {
        case .failed(.nothingRecognized): break
        case .mixed(let parts):
            #expect(parts.allSatisfy {
                if case .failed(.nothingRecognized) = $0 { return true }; return false })
        default: Issue.record("got \(outcome)")
        }
    }

    @Test func cuePullsItsTracksIntoPs1() async throws {
        let dir = try tempFolder([
            "game.cue": "FILE \"game (Track 1).bin\" BINARY\n  TRACK 01 MODE2/2352\n    INDEX 01 00:00:00\n",
        ])
        try Data(count: 600).write(to: dir.appending(path: "game (Track 1).bin"))
        let outcome = try await DropClassifier().classify([
            dir.appending(path: "game.cue"), dir.appending(path: "game (Track 1).bin"),
        ])
        guard case .roms(let r) = outcome else { Issue.record("got \(outcome)"); return }
        #expect(r.groups == [ConsoleGroup(console: "ps1", files: [
            dir.appending(path: "game (Track 1).bin"), dir.appending(path: "game.cue"),
        ])])
    }

    @Test func pspIsoBySignature() async throws {
        let dir = try tempFolder([:])
        var data = Data(count: 512)
        data.replaceSubrange(64 ..< 72, with: Data("PSP_GAME".utf8))
        try data.write(to: dir.appending(path: "djmax.iso"))
        let outcome = try await DropClassifier().classify([dir.appending(path: "djmax.iso")])
        guard case .roms(let r) = outcome else { Issue.record("got \(outcome)"); return }
        #expect(r.groups.first?.console == "psp")
    }

    @Test func aFolderOfRoms() async throws {
        let dir = try tempFolder([:])
        try FileManager.default.createDirectory(at: dir.appending(path: "nes"), withIntermediateDirectories: true)
        try nes().write(to: dir.appending(path: "nes/a.nes"))
        try gameboy().write(to: dir.appending(path: "b.gb"))
        try "cover".write(to: dir.appending(path: "cover.png"), atomically: true, encoding: .utf8)
        let outcome = try await DropClassifier().classify([dir])
        guard case .roms(let r) = outcome else { Issue.record("got \(outcome)"); return }
        #expect(r.groups.map(\.console).sorted() == ["gb", "nes"])
        #expect(r.unknown.isEmpty)
    }

    @Test func mysteryFilesAreUnrecognized() async throws {
        let dir = try tempFolder(["notes.docx": "x"])
        let outcome = try await DropClassifier().classify([dir.appending(path: "notes.docx")])
        guard case .failed(.nothingRecognized(let urls)) = outcome else {
            Issue.record("got \(outcome)"); return
        }
        #expect(urls == [dir.appending(path: "notes.docx")])
    }

    @Test func mixedDrop() async throws {
        let game = try Self.gameFolder()
        let roms = try tempFolder([:])
        try nes().write(to: roms.appending(path: "a.nes"))
        let outcome = try await DropClassifier().classify([game, roms.appending(path: "a.nes")])
        guard case .mixed(let outcomes) = outcome else { Issue.record("got \(outcome)"); return }
        #expect(outcomes.count == 2)
        #expect(outcomes.contains { if case .installedGame = $0 { true } else { false } })
        #expect(outcomes.contains { if case .roms = $0 { true } else { false } })
    }

    // MARK: archives

    @Test func aZipOfRomsStaysZipped() async throws {
        let dir = try tempFolder(["roms.zip": "x"])
        let work = try tempFolder([:])
        let p = probe([("a.sfc", .file), ("b.sfc", .file), ("readme.txt", .file)])
        let outcome = try await classifier(probe: p, workspace: work)
            .classify([dir.appending(path: "roms.zip")])
        guard case .roms(let r) = outcome else { Issue.record("got \(outcome)"); return }
        #expect(r.groups == [ConsoleGroup(console: "snes", files: [dir.appending(path: "roms.zip")])])
    }

    @Test func aZipOfAnInstallerExtractsThenClassifies() async throws {
        let dir = try tempFolder(["go g.zip": "x"])
        let work = try tempFolder([:])
        let p = probe([("setup_game.exe", .file), ("data-01.bin", .file)])
        let outcome = try await classifier(probe: p, workspace: work)
            .classify([dir.appending(path: "go g.zip")])
        guard case .installer(let i) = outcome else { Issue.record("got \(outcome)"); return }
        #expect(i.setup.lastPathComponent == "setup_game.exe")
        // The extracted folder stays put under the workspace.
        #expect(i.setup.path.hasPrefix(work.path))
    }

    @Test func encryptedArchives() async throws {
        let dir = try tempFolder(["locked.zip": "x"])
        let work = try tempFolder([:])
        let p = probe([("x", .file)], encrypted: true)
        let outcome = try await classifier(probe: p, workspace: work)
            .classify([dir.appending(path: "locked.zip")])
        guard case .failed(.passwordProtected) = outcome else { Issue.record("got \(outcome)"); return }
    }

    @Test func missingMiddleVolume() async throws {
        let dir = try tempFolder(["g.part1.rar": "x", "g.part3.rar": "x"])
        let work = try tempFolder([:])
        let outcome = try await classifier(probe: probe([("x", .file)]), workspace: work)
            .classify([dir.appending(path: "g.part3.rar")])
        guard case .failed(.missingVolume(let url, let name)) = outcome else {
            Issue.record("got \(outcome)"); return
        }
        #expect(url.lastPathComponent == "g.part1.rar")
        #expect(name == "g.part2.rar")
    }

    @Test func noEngineMeansUnsupported() async throws {
        let dir = try tempFolder(["a.7z": "x"])
        let outcome = try await DropClassifier(extractor: nil)
            .classify([dir.appending(path: "a.7z")])
        guard case .failed(.unsupportedArchive) = outcome else { Issue.record("got \(outcome)"); return }
    }

    @Test func part2DropsClassifyTheWholeSet() async throws {
        let dir = try tempFolder(["g.part1.rar": "x", "g.part2.rar": "x"])
        let work = try tempFolder([:])
        let p = probe([("setup_a.exe", .file)])
        let c = DropClassifier(extractor: ArchiveExtractor(engine: FakeEngine(probeResult: p),
                                                           freeBytes: { _ in Int64.max / 4 }),
                               workspace: work)
        let outcome = try await c.classify([dir.appending(path: "g.part2.rar")])
        guard case .installer = outcome else { Issue.record("got \(outcome)"); return }
    }
}
