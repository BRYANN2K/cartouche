import Foundation
import Testing
@testable import InstallerKit

// The dylib built by `make libarchive`, next to the package. Live tests skip
// when it is missing so the fake-engine suite still runs everywhere.
private let dylib = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // InstallerKitTests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // installer
    .deletingLastPathComponent()  // repo root
    .appending(path: "out/libarchive.dylib")
private let liveOK = FileManager.default.fileExists(atPath: dylib.path(percentEncoded: false))
private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appending(path: "Fixtures/archives", directoryHint: .isDirectory)

private func engine() throws -> LibarchiveEngine {
    try LibarchiveEngine(library: dylib.path(percentEncoded: false))
}

// Copies the fixture(s) next to the live tests so volume sets sit in a scratch folder.
@discardableResult
private func fixture(_ name: String, into parent: URL? = nil) throws -> URL {
    let src = fixtures.appending(path: name)
    guard let parent else { return src }
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    let dst = parent.appending(path: name)
    try FileManager.default.copyItem(at: src, to: dst)
    return dst
}

// A stored-entry zip written by hand so tests can carry hostile pathnames
// the fixtures cannot.
private func storedZip(_ entries: [(String, Data)]) -> Data {
    var out = Data()
    var central = Data()
    for (name, data) in entries {
        let offset = UInt32(out.count)
        let n = name.data(using: .utf8)!
        var crc: UInt32 = ~0
        for b in data {
            crc ^= UInt32(b)
            for _ in 0 ..< 8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xEDB8_8320 : 0) }
        }
        crc = ~crc
        var local = Data()
        local.appendU32(0x0403_4B50); local.appendU16(20); local.appendU16(0x0800) // UTF-8
        local.appendU16(0); local.appendU16(0); local.appendU16(0)
        local.appendU32(crc); local.appendU32(UInt32(data.count)); local.appendU32(UInt32(data.count))
        local.appendU16(UInt16(n.count)); local.appendU16(0); local.append(n)
        out.append(local); out.append(data)

        central.appendU32(0x0201_4B50); central.appendU16(20); central.appendU16(20)
        central.appendU16(0x0800); central.appendU16(0); central.appendU16(0); central.appendU16(0)
        central.appendU32(crc); central.appendU32(UInt32(data.count)); central.appendU32(UInt32(data.count))
        central.appendU16(UInt16(n.count)); central.appendU16(0); central.appendU16(0)
        central.appendU16(0); central.appendU16(0); central.appendU32(0)
        central.appendU32(offset); central.append(n)
    }
    let start = UInt32(out.count)
    out.append(central)
    var end = Data()
    end.appendU32(0x0605_4B50); end.appendU16(0); end.appendU16(0)
    end.appendU16(UInt16(entries.count)); end.appendU16(UInt16(entries.count))
    end.appendU32(UInt32(central.count)); end.appendU32(start); end.appendU16(0)
    out.append(end)
    return out
}

private extension Data {
    mutating func appendU16(_ v: UInt16) { var x = v.littleEndian; append(Data(bytes: &x, count: 2)) }
    mutating func appendU32(_ v: UInt32) { var x = v.littleEndian; append(Data(bytes: &x, count: 4)) }
}

// Serves entries from memory so the routing/staging/cancellation logic is
// exercised without the dylib.
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
        var written: Int64 = 0
        for entry in probeResult.entries {
            if isCancelled() { throw CancellationError() }
            guard case .write(let dest) = try route(entry) else { continue }
            if entry.kind == .directory {
                try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            } else {
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try Data(repeating: 0x61, count: Int(entry.size)).write(to: dest)
                written += entry.size
                bytesDone(written)
            }
        }
    }
}

private func probe(_ entries: [(String, Int64, ArchiveEntry.Kind)], encrypted: Bool = false,
                   format: ArchiveFormat = .zip) -> ArchiveProbe {
    ArchiveProbe(
        format: format, formatName: "fake", filters: [],
        entries: entries.map { ArchiveEntry(path: $0.0, size: $0.1, kind: $0.2, linkTarget: nil) },
        hasEncryptedEntries: encrypted,
        uncompressedSize: entries.filter { $0.2 == .file }.reduce(0) { $0 + $1.1 })
}

@Suite("Volume sets")
struct VolumeSetTests {

    private func listing(_ names: [String]) -> (URL) -> [URL] {
        { parent in names.map { parent.appending(path: $0) } }
    }
    private let here = URL(filePath: "/tmp/drops", directoryHint: .isDirectory)

    @Test func rarParts() {
        let set = ArchiveVolumes.set(for: here.appending(path: "game.part3.rar"),
                                     listing: listing(["game.part1.rar", "game.part2.rar", "game.part3.rar"]))
        #expect(set?.volumes.map(\.lastPathComponent) == ["game.part1.rar", "game.part2.rar", "game.part3.rar"])
        #expect(set?.missing.isEmpty == true)
    }

    @Test func rarPartsGap() {
        let set = ArchiveVolumes.set(for: here.appending(path: "game.part2.rar"),
                                     listing: listing(["game.part1.rar", "game.part2.rar", "game.part4.rar"]))
        #expect(set?.missing == ["game.part3.rar"])
        #expect(set?.volumes.map(\.lastPathComponent) == ["game.part1.rar", "game.part2.rar"])
    }

    @Test func oldStyleRNN() {
        let set = ArchiveVolumes.set(for: here.appending(path: "game.r02"),
                                     listing: listing(["game.rar", "game.r00", "game.r01", "game.r02"]))
        #expect(set?.volumes.map(\.lastPathComponent) == ["game.rar", "game.r00", "game.r01", "game.r02"])
    }

    @Test func oldStyleMissingHead() {
        let set = ArchiveVolumes.set(for: here.appending(path: "game.r00"),
                                     listing: listing(["game.r00", "game.r01"]))
        #expect(set?.missing == ["game.rar"])
    }

    @Test func sevenZipNumbered() {
        let set = ArchiveVolumes.set(for: here.appending(path: "disc.7z.002"),
                                     listing: listing(["disc.7z.001", "disc.7z.002", "disc.7z.003"]))
        #expect(set?.volumes.map(\.lastPathComponent) == ["disc.7z.001", "disc.7z.002", "disc.7z.003"])
    }

    @Test func zipDiskChain() {
        let set = ArchiveVolumes.set(for: here.appending(path: "rom.z02"),
                                     listing: listing(["rom.zip", "rom.z01", "rom.z02"]))
        #expect(set?.volumes.map(\.lastPathComponent) == ["rom.zip", "rom.z01", "rom.z02"])
    }

    @Test func singleStaysSingle() throws {
        let dir = try tempFolder(["a.zip": "x"])
        #expect(ArchiveVolumes.set(for: dir.appending(path: "a.zip")) == nil)
    }
}

@Suite("Path sanitization")
struct SanitizeTests {
    private func dest(_ path: String, kind: ArchiveEntry.Kind = .file) throws -> EntryDestination {
        try EntryRouting.destination(
            for: ArchiveEntry(path: path, size: 1, kind: kind),
            under: URL(filePath: "/tmp/root", directoryHint: .isDirectory))
    }

    @Test func dotdotOutsideIsRejected() {
        #expect(throws: ArchiveError.self) { try dest("../evil.txt") }
        #expect(throws: ArchiveError.self) { try dest("a/b/../../../evil.txt") }
    }

    @Test func absoluteIsRejected() {
        #expect(throws: ArchiveError.self) { try dest("/etc/passwd") }
        #expect(throws: ArchiveError.self) { try dest("\\Windows\\system.ini") }
        #expect(throws: ArchiveError.self) { try dest("C:\\Windows\\system.ini") }
    }

    @Test func insideDotDotIsKept() throws {
        #expect(try dest("a/../b") == .write(URL(filePath: "/tmp/root/b")))
        #expect(try dest("dir/./file") == .write(URL(filePath: "/tmp/root/dir/file")))
    }

    @Test func linksAndSpecialsAreSkipped() throws {
        #expect(try dest("x", kind: .symlink) == .skip)
        #expect(try dest("x", kind: .hardlink) == .skip)
        #expect(try dest("x", kind: .other) == .skip)
        guard case .write(let dirDest) = try dest("dir", kind: .directory) else {
            Issue.record("directory was not routed to write"); return
        }
        #expect(dirDest.path(percentEncoded: false) == "/tmp/root/dir")
    }

    @Test func encryptedIsRejected() {
        var entry = ArchiveEntry(path: "x", size: 1, kind: .file)
        entry.isEncrypted = true
        #expect(throws: ArchiveError.self) {
            try EntryRouting.destination(for: entry, under: URL(filePath: "/tmp/root"))
        }
    }
}

@Suite("Extractor with a fake engine")
struct ExtractorTests {

    @Test func extractStagesThenMoves() throws {
        let src = try tempFolder(["game.zip": "x"])
        let dst = try tempFolder([:])
        let extractor = ArchiveExtractor(engine: FakeEngine(probeResult: probe([
            ("game/file1", 10, .file), ("game/dir", 0, .directory), ("game/dir/f2", 5, .file),
        ])), freeBytes: { _ in Int64.max / 4 })
        let result = try extractor.extract(src.appending(path: "game.zip"), to: dst)
        #expect(result.files == 2)
        #expect(result.bytes == 15)
        #expect(FileManager.default.fileExists(atPath: result.root.appending(path: "game/file1").path))
        // Staging is gone.
        #expect((try? FileManager.default.contentsOfDirectory(atPath: dst.path))?.filter {
            $0.hasPrefix(".cartouche-drop-") }.isEmpty == true)
    }

    @Test func cancellationCleansStaging() throws {
        let src = try tempFolder(["game.zip": "x"])
        let dst = try tempFolder([:])
        let extractor = ArchiveExtractor(engine: FakeEngine(probeResult: probe([
            ("game/a", 10, .file), ("game/b", 10, .file),
        ])), freeBytes: { _ in Int64.max / 4 })
        #expect(throws: CancellationError.self) {
            try extractor.extract(src.appending(path: "game.zip"), to: dst, isCancelled: { true })
        }
        #expect((try? FileManager.default.contentsOfDirectory(atPath: dst.path))?.isEmpty == true)
    }

    @Test func diskSpaceIsCheckedFirst() throws {
        let src = try tempFolder(["game.zip": "x"])
        let dst = try tempFolder([:])
        var extractor = ArchiveExtractor(engine: FakeEngine(probeResult: probe([("g/f", 1, .file)])),
                                        freeBytes: { _ in 0 })
        extractor.spaceReserve = .max / 2
        do {
            try extractor.extract(src.appending(path: "game.zip"), to: dst)
            Issue.record("should have refused on space")
        } catch let error as ArchiveError {
            guard case .insufficientSpace = error else { Issue.record("got \(error)"); return }
        }
    }

    @Test func unsafeEntryAbortsWithNothingLeft() throws {
        let src = try tempFolder(["game.zip": "x"])
        let dst = try tempFolder([:])
        let extractor = ArchiveExtractor(engine: FakeEngine(probeResult: probe([
            ("game/ok", 1, .file), ("../evil", 1, .file),
        ])), freeBytes: { _ in Int64.max / 4 })
        #expect(throws: ArchiveError.self) {
            try extractor.extract(src.appending(path: "game.zip"), to: dst)
        }
        #expect((try? FileManager.default.contentsOfDirectory(atPath: dst.path))?.isEmpty == true)
    }

    @Test func missingVolumeIsNamed() throws {
        let src = try tempFolder(["g.part1.rar": "x", "g.part3.rar": "x"])
        let dst = try tempFolder([:])
        let extractor = ArchiveExtractor(engine: FakeEngine(probeResult: probe([("f", 1, .file)])), freeBytes: { _ in Int64.max / 4 })
        #expect(throws: ArchiveError.missingVolume("g.part2.rar")) {
            try extractor.extract(src.appending(path: "g.part3.rar"), to: dst)
        }
    }
}

@Suite("Bundled libarchive", .enabled(if: liveOK))
struct LiveArchiveTests {

    @Test func versionIsThePinnedOne() throws {
        #expect(try engine().versionString.contains("3.8.9"))
    }

    @Test(.enabled(if: liveOK)) func zipProbeAndExtract() throws {
        let probe = try engine().probe([try fixture("plain.zip")])
        #expect(probe.format == .zip)
        #expect(probe.entries.map(\.path) == ["abc", "def/", "def/foo", "ghi/", "jkl/", "mno/"])

        let dst = try tempFolder([:])
        let extractor = ArchiveExtractor(engine: try engine(), freeBytes: { _ in Int64.max / 4 })
        let result = try extractor.extract(try fixture("plain.zip"), to: dst)
        #expect(result.files == 2)
        #expect(FileManager.default.fileExists(atPath: result.root.appending(path: "def/foo").path))
    }

    @Test(.enabled(if: liveOK)) func tarCodecs() throws {
        for (file, filter) in [("plain.tgz", "gzip"), ("plain.txz", "xz"), ("plain.tar.zst", "zstd")] {
            let probe = try engine().probe([try fixture(file)])
            #expect(probe.format == .tar)
            #expect(probe.filters.contains(filter))
            #expect(probe.entries.filter { $0.kind == .file }.count == 6)
        }
        #expect(try engine().probe([try fixture("plain.tar")]).format == .tar)
    }

    @Test(.enabled(if: liveOK)) func zip64() throws {
        let probe = try engine().probe([try fixture("zip64.zip")])
        #expect(probe.format == .zip)
        #expect(probe.entries.map(\.path) == ["-"])
        let dst = try tempFolder([:])
        let extractor = ArchiveExtractor(engine: try engine(), freeBytes: { _ in Int64.max / 4 })
        let result = try extractor.extract(try fixture("zip64.zip"), to: dst)
        #expect(result.files == 1)
    }

    @Test(.enabled(if: liveOK)) func sevenZip() throws {
        let probe = try engine().probe([try fixture("lzma2.7z")])
        #expect(probe.format == .sevenZip)
        #expect(probe.entries.map(\.path) == ["x86exe"])
    }

    @Test(.enabled(if: liveOK)) func rar4And5() throws {
        #expect(try engine().probe([try fixture("rar4.rar")]).format == .rar)
        #expect(try engine().probe([try fixture("rar5.rar")]).format == .rar5)
        #expect(try engine().probe([try fixture("rar5_solid.rar")]).format == .rar5)
        let dst = try tempFolder([:])
        let extractor = ArchiveExtractor(engine: try engine(), freeBytes: { _ in Int64.max / 4 })
        let result = try extractor.extract(try fixture("rar5_solid.rar"), to: dst)
        #expect(result.files == 7)
    }

    @Test(.enabled(if: liveOK)) func rar4ExtractsAndSkipsLinks() throws {
        let dst = try tempFolder([:])
        let extractor = ArchiveExtractor(engine: try engine(), freeBytes: { _ in Int64.max / 4 })
        let result = try extractor.extract(try fixture("rar4.rar"), to: dst)
        #expect(FileManager.default.fileExists(atPath: result.root.appending(path: "testdir/test.txt").path))
        #expect(result.skipped == ["testlink"])
        var isLink: ObjCBool = false
        let link = result.root.appending(path: "testlink")
        #expect(!FileManager.default.fileExists(atPath: link.path, isDirectory: &isLink))
    }

    @Test(.enabled(if: liveOK)) func middleVolumeOpensFromPart2() throws {
        let dir = try tempFolder([:])
        try fixture("mv4.part1.rar", into: dir)
        try fixture("mv4.part2.rar", into: dir)
        try fixture("mv4.part3.rar", into: dir)
        let dst = try tempFolder([:])
        let extractor = ArchiveExtractor(engine: try engine(), freeBytes: { _ in Int64.max / 4 })
        // Dropped part 2: the set still starts at part 1.
        let result = try extractor.extract(dir.appending(path: "mv4.part2.rar"), to: dst)
        #expect(result.files == 1)
        #expect(FileManager.default.fileExists(
            atPath: result.root.appending(path: "LibarchiveAddingTest.html").path))
    }

    @Test(.enabled(if: liveOK)) func rar5Multiarchive() throws {
        let dir = try tempFolder([:])
        for n in 1 ... 8 { try fixture(String(format: "mv5.part%02d.rar", n), into: dir) }
        let dst = try tempFolder([:])
        let extractor = ArchiveExtractor(engine: try engine(), freeBytes: { _ in Int64.max / 4 })
        let result = try extractor.extract(dir.appending(path: "mv5.part01.rar"), to: dst)
        #expect(result.files >= 1)
        #expect(result.bytes > 100_000)
    }

    @Test(.enabled(if: liveOK)) func missingMiddleVolumeFails() throws {
        let dir = try tempFolder([:])
        try fixture("mv4.part1.rar", into: dir)
        try fixture("mv4.part3.rar", into: dir)
        let dst = try tempFolder([:])
        let extractor = ArchiveExtractor(engine: try engine(), freeBytes: { _ in Int64.max / 4 })
        #expect(throws: ArchiveError.missingVolume("mv4.part2.rar")) {
            try extractor.extract(dir.appending(path: "mv4.part3.rar"), to: dst)
        }
    }

    @Test(.enabled(if: liveOK)) func encryptedArchivesFailClearly() throws {
        for name in ["encrypted.rar", "encrypted5.rar", "encrypted.zip"] {
            let dst = try tempFolder([:])
            let extractor = ArchiveExtractor(engine: try engine(), freeBytes: { _ in Int64.max / 4 })
            #expect(throws: ArchiveError.passwordProtected) {
                try extractor.extract(try fixture(name), to: dst)
            }
            #expect((try? FileManager.default.contentsOfDirectory(atPath: dst.path))?.isEmpty == true)
        }
    }

    @Test(.enabled(if: liveOK)) func symlinksAreDropped() throws {
        let dst = try tempFolder([:])
        let extractor = ArchiveExtractor(engine: try engine(), freeBytes: { _ in Int64.max / 4 })
        let result = try extractor.extract(try fixture("symlink.zip"), to: dst)
        #expect(result.skipped == ["symlink"])
        #expect(FileManager.default.fileExists(atPath: result.root.appending(path: "file").path))
        #expect(!FileManager.default.fileExists(atPath: result.root.appending(path: "symlink").path))
    }

    @Test(.enabled(if: liveOK)) func traversalIsRejected() throws {
        let src = try tempFolder([:])
        let zip = storedZip([("good/ok.txt", Data("ok".utf8)),
                             ("../escaped.txt", Data("no".utf8)),
                             ("a/../../also.txt", Data("no".utf8))])
        let archive = src.appending(path: "evil.zip")
        try zip.write(to: archive)
        let dst = try tempFolder([:])
        let extractor = ArchiveExtractor(engine: try engine(), freeBytes: { _ in Int64.max / 4 })
        #expect(throws: ArchiveError.self) {
            try extractor.extract(archive, to: dst)
        }
        // Nothing outside staging; staging itself is gone.
        #expect(!FileManager.default.fileExists(atPath: dst.appending(path: "../escaped.txt").path))
        #expect((try? FileManager.default.contentsOfDirectory(atPath: dst.path))?.isEmpty == true)
    }
}
