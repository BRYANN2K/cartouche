import Foundation
import Testing
@testable import InstallerKit

// md5 of "a", "b" and "c"
private let sumA = "0cc175b9c0f1b6a831c399e269772661"
private let sumB = "92eb5ffee6ae2fec3ad71c777531578f"
private let sumC = "4a8a08f09d37b73795649038408b5f33"

private func manifest(optional: Bool, extra: String = "") -> String {
    (optional ? "; some parts are optional downloads\r\n" : "; Checksums for this installer\r\n")
        + "\(sumA) *..\\data-01.bin\r\n\(sumB) *..\\data-02.bin\r\n\(sumC) *..\\data-03.bin\r\n" + extra
}

private let noInno = RecordingRunner(answers: ["--info": "Not a supported Inno Setup installer!"])

@Suite("Analysis")
struct AnalysisTests {

    @Test("A required part that is missing is red, named, and blocks Install")
    func requiredMissingBlocks() async throws {
        let dir = try tempFolder(["setup.exe": "MZ", "data-01.bin": "a", "data-03.bin": "c", "MD5/checksums.md5": manifest(optional: false)])
        let analysis = try await Analyzer.analyze(dir, tool: "/x/innoextract", runner: noInno)
        #expect(analysis.missing == [MissingPart(file: "data-02.bin", mayBeOptional: false)])
        #expect(analysis.blockingProblems == ["data-02.bin"])
        #expect(!analysis.canInstall)
    }

    @Test("When the manifest says parts may be optional, a missing one is orange and Install stays enabled")
    func optionalMissingWarns() async throws {
        let dir = try tempFolder(["setup.exe": "MZ", "data-01.bin": "a", "data-03.bin": "c", "MD5/checksums.md5": manifest(optional: true)])
        let analysis = try await Analyzer.analyze(dir, tool: "/x/innoextract", runner: noInno)
        #expect(analysis.missing == [MissingPart(file: "data-02.bin", mayBeOptional: true)])
        #expect(analysis.blockingProblems.isEmpty)
        #expect(analysis.canInstall)
    }

    @Test("A manifest entry outside the numbering that is absent is also listed")
    func manifestOnlyPartMissing() async throws {
        let dir = try tempFolder([
            "setup.exe": "MZ", "data-01.bin": "a", "data-02.bin": "b", "data-03.bin": "c",
            "MD5/checksums.md5": manifest(optional: true, extra: "\(sumA) *..\\data-french.bin\r\n"),
        ])
        let analysis = try await Analyzer.analyze(dir, tool: "/x/innoextract", runner: noInno)
        #expect(analysis.missing.map(\.file) == ["data-french.bin"])
        #expect(analysis.missing.allSatisfy { $0.mayBeOptional })
        #expect(analysis.canInstall)
    }

    @Test("Every part present and matching: checksums OK and Install enabled")
    func allGood() async throws {
        let dir = try tempFolder(["setup.exe": "MZ", "data-01.bin": "a", "data-02.bin": "b", "data-03.bin": "c", "MD5/checksums.md5": manifest(optional: false)])
        let analysis = try await Analyzer.analyze(dir, tool: "/x/innoextract", runner: noInno)
        #expect(analysis.scan.parts.count == 3)
        #expect(analysis.missing.isEmpty)
        #expect(analysis.checksumsOK)
        #expect(analysis.canInstall)
    }

    @Test("A damaged part blocks Install even when parts may be optional")
    func damagedBlocks() async throws {
        let dir = try tempFolder(["setup.exe": "MZ", "data-01.bin": "a", "data-02.bin": "x", "data-03.bin": "c", "MD5/checksums.md5": manifest(optional: true)])
        let analysis = try await Analyzer.analyze(dir, tool: "/x/innoextract", runner: noInno)
        #expect(analysis.damaged == ["data-02.bin"])
        #expect(!analysis.checksumsOK)
        #expect(!analysis.canInstall)
    }

    @Test("No setup.exe blocks Install")
    func noSetup() async throws {
        let dir = try tempFolder(["data-01.bin": "a"])
        let analysis = try await Analyzer.analyze(dir, verify: false, tool: "/x/innoextract", runner: noInno)
        #expect(analysis.blockingProblems == ["setup"])
    }

    @Test("A dropped setup.exe stands for its folder")
    func droppedSetup() throws {
        let dir = try tempFolder(["setup.exe": "MZ", "data-01.bin": "a"])
        #expect(Analyzer.folder(for: dir.appending(path: "setup.exe")).standardizedFileURL == dir.standardizedFileURL)
        #expect(Analyzer.folder(for: dir) == dir)
    }

    @Test("Checksum progress adds up to the bytes hashed")
    func checksumProgress() async throws {
        let dir = try tempFolder(["data-01.bin": "a", "data-02.bin": "b", "sums.md5": "\(sumA) *data-01.bin\n\(sumB) *data-02.bin\n"])
        let total = Counter()
        _ = await Checksums.verify(try Checksums.parse(dir.appending(path: "sums.md5"))) { total.add($0) }
        #expect(total.value == 2)
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count: Int64 = 0
    var value: Int64 { lock.withLock { count } }
    func add(_ n: Int64) { lock.withLock { count += n } }
}
