import Foundation
import Testing
@testable import InstallerKit

func tempFolder(_ files: [String: String]) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appending(path: "ik-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for (path, content) in files {
        let url = dir.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }
    return dir
}

@Test func findsPartsWhateverTheirPrefix() throws {
    let dir = try tempFolder(["setup.exe": "MZ", "data-01.bin": "a", "data-02.bin": "bb", "data-04.bin": "c", "readme.txt": ""])
    let scan = try PartScanner.scan(dir)
    #expect(scan.setup?.lastPathComponent == "setup.exe")
    #expect(scan.parts.map(\.number) == [1, 2, 4])
    #expect(scan.missing == ["data-03.bin"])
    #expect(scan.totalSize == 4)
}

@Test func unrelatedNumberedBinsAreNotParts() throws {
    let dir = try tempFolder([
        "setup.exe": "MZ", "data-01.bin": "a", "data-02.bin": "b", "data-03.bin": "c",
        "bios2.bin": "x", "firmware_1.bin": "y",
    ])
    let scan = try PartScanner.scan(dir)
    #expect(scan.parts.map(\.url.lastPathComponent) == ["data-01.bin", "data-02.bin", "data-03.bin"])
    #expect(scan.missing.isEmpty)
}

@Test func partsFollowTheManifestOrTheSetupName() throws {
    // The manifest names the fg- group, even though a bigger unrelated group sits next to it.
    let fitgirl = try tempFolder([
        "setup.exe": "MZ", "fg-01.bin": "a", "fg-02.bin": "b",
        "track01.bin": "x", "track02.bin": "y", "track03.bin": "z",
        "MD5/fitgirl.md5": "0cc175b9c0f1b6a831c399e269772661 *..\\fg-01.bin\r\n92eb5ffee6ae2fec3ad71c777531578f *..\\fg-02.bin\r\n",
        "Music/album.md5": "0cc175b9c0f1b6a831c399e269772661 *cover.jpg\r\n",
    ])
    #expect(try PartScanner.scan(fitgirl).parts.map(\.url.lastPathComponent) == ["fg-01.bin", "fg-02.bin"])
    #expect(Checksums.installerManifest(in: fitgirl)?.source.lastPathComponent == "fitgirl.md5")

    // No manifest: the group carrying the setup's name.
    let gog = try tempFolder([
        "setup_game_1.0.exe": "MZ", "setup_game_1.0-1.bin": "a", "setup_game_1.0-2.bin": "b",
        "other-1.bin": "x", "other-2.bin": "y", "other-3.bin": "z",
    ])
    #expect(try PartScanner.scan(gog).parts.map(\.url.lastPathComponent) == ["setup_game_1.0-1.bin", "setup_game_1.0-2.bin"])
}

@Test func anUnrelatedManifestIsNotTheInstallers() throws {
    let dir = try tempFolder([
        "setup.exe": "MZ", "data-01.bin": "a",
        "Music/album.md5": "0cc175b9c0f1b6a831c399e269772661 *cover.jpg\r\n",
    ])
    #expect(Checksums.installerManifest(in: dir) == nil)
}

@Test func findsSplitArchives() throws {
    let dir = try tempFolder(["setup.exe": "", "data.bin.001": "", "data.bin.002": ""])
    #expect(try PartScanner.scan(dir).parts.count == 2)
}

@Test func parsesManifestInSubfolderWithWindowsPaths() throws {
    let dir = try tempFolder([
        "MD5/checksums.md5": "; If you miss selective download files - that's OK\r\nd8396f99cb7a7f3fbd9369b0720823f8 *..\\data-01.bin\r\n",
        "data-01.bin": "x",
    ])
    let manifest = try #require(Checksums.findManifest(in: dir))
    let parsed = try Checksums.parse(manifest)
    #expect(parsed.mentionsOptionalParts)
    #expect(parsed.entries.count == 1)
    #expect(parsed.entries[0].file.lastPathComponent == "data-01.bin")
    #expect(parsed.entries[0].file.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL)
}

@Test func verifiesChecksums() async throws {
    // md5("hello") = 5d41402abc4b2a76b9719d911017c592
    let dir = try tempFolder(["a.bin": "hello", "b.bin": "nope", "sums.md5": "5d41402abc4b2a76b9719d911017c592 *a.bin\n5d41402abc4b2a76b9719d911017c592 *b.bin\n5d41402abc4b2a76b9719d911017c592 *c.bin\n"])
    let results = try await Checksums.verify(try Checksums.parse(dir.appending(path: "sums.md5")))
    #expect(results[dir.appending(path: "a.bin").standardizedFileURL] == .ok)
    #expect(results[dir.appending(path: "c.bin").standardizedFileURL] == .absent)
    if case .mismatch = results[dir.appending(path: "b.bin").standardizedFileURL] {} else { Issue.record("b.bin should mismatch") }
}

@Test func manifestEntriesOutsideTheInstallerFolderAreNotHashed() async throws {
    // A manifest in MD5/ refers to the installer root as "..\"; anything further out is skipped.
    let dir = try tempFolder([
        "MD5/checksums.md5": "d8396f99cb7a7f3fbd9369b0720823f8 *..\\data-01.bin\n5d41402abc4b2a76b9719d911017c592 *..\\..\\escaped.bin\n",
        "data-01.bin": "x",
    ])
    let manifest = try Checksums.parse(dir.appending(path: "MD5/checksums.md5"))
    let results = try await Checksums.verify(manifest, root: dir)
    #expect(results.count == 1)
    let actual = try Checksums.md5(of: dir.appending(path: "data-01.bin"))
    #expect(results[dir.appending(path: "data-01.bin").standardizedFileURL] == .mismatch(expected: "d8396f99cb7a7f3fbd9369b0720823f8", actual: actual))
}

@Test func verifyThrowsOnCancellationInsteadOfReportingEverythingAbsent() async throws {
    let dir = try tempFolder(["a.bin": "hello", "sums.md5": "5d41402abc4b2a76b9719d911017c592 *a.bin\n"])
    let manifest = try Checksums.parse(dir.appending(path: "sums.md5"))
    let task = Task { try await Checksums.verify(manifest) }
    task.cancel()
    await #expect(throws: CancellationError.self) { _ = try await task.value }
}

@Test func readsInnoextractOutput() {
    let info = """
    Inspecting "CarX Street" - setup data version 5.5.0.1 (unicode)

    Languages:
     - en: English
     - russian: Русский

    Setup is not passworded!
    """
    let list = "tmp/idp.dll\ntmp/botva2.dll\ntmp/unarc.dll\ntmp/cls-srep_x64.exe\ntmp/ISDone.dll\napp/_Redist/dxwebsetup.exe\napp/_Redist/QuickSFV.EXE\n"
    let r = InnoInspector.parse(info: info, list: list)
    #expect(r.title == "CarX Street")
    #expect(r.version == "5.5.0.1")
    #expect(r.languages == ["en", "russian"])
    #expect(!r.passworded)
    #expect(r.heavyDecompression)
    #expect(r.customInterface)
    #expect(r.downloadsDuringInstall)
    #expect(r.redistributables == ["app/_Redist/dxwebsetup.exe"])
}

@Test(arguments: [
    ("CarX Street [Offline Installer]", "CarX Street"),
    ("The Witcher 3 Wild Hunt GOTY (Offline Installer) v4.04 + 2 DLCs", "The Witcher 3 Wild Hunt GOTY"),
    ("Hollow_Knight_v1.5.78-GOG", "Hollow Knight"),
    ("Hollow-Knight-Silksong-SteamRIP.com", "Hollow Knight Silksong"),
    ("Some_Game.v1.2.3-[Repack]", "Some Game"),
    ("Game Name Build 12345 (x64)", "Game Name"),
    ("The-Game-www.example.net-MULTi9", "The Game"),
    ("A.Game.Portable", "A Game"),
])
func cleansGameNames(folder: String, expected: String) {
    #expect(GameName.clean(folder) == expected)
}

@Test func buildsInnoCommand() {
    #expect(InnoCommand(installDir: #"C:\Games\CarX Street"#, mode: .automatic).arguments.contains("/VERYSILENT"))
    #expect(!InnoCommand(installDir: #"C:\Games\X"#, mode: .guided).arguments.contains("/VERYSILENT"))
}

@Test func ranksExecutables() {
    let ranked = ExeDetector.rank(
        exes: [("Game/unins000.exe", 3_000_000), ("Game/witcher3.exe", 60_000_000), ("Game/REDprelauncher.exe", 5_000_000), ("Game/_Redist/dxwebsetup.exe", 300_000)],
        shortcuts: ["Game/witcher3.exe"]
    )
    #expect(ranked.map(\.path) == ["Game/witcher3.exe", "Game/REDprelauncher.exe"])
    #expect(ranked[0].reason == "From the Start Menu shortcut")
}

@Test func estimatesSpaceWithTempFiles() {
    let s = SpaceEstimate.from(compressed: 10 << 30, heavy: true)
    #expect(s.installed == 25 << 30)
    #expect(s.temporary >= 2 << 30)
}
