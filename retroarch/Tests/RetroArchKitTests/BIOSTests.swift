import CryptoKit
import Foundation
import Testing

@testable import RetroArchKit

@Suite("Core info and BIOS")
struct BIOSTests {

    private static let ps1US = "490f666e1afb15b7362b406ed1cea246"

    private func infoText(_ core: String) throws -> String {
        try String(contentsOf: Fixtures.url("info/\(core)_libretro.info"), encoding: .utf8)
    }

    private func md5(_ data: Data) -> String { Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private func setup(_ core: String, info: String? = nil) throws -> RetroArchPaths {
        let paths = RetroArchPaths(root: try scratchFolder("bios"))
        try paths.create()
        try (info ?? infoText(core)).write(
            to: paths.coreInfo.appending(path: "\(core)_libretro.info"), atomically: true, encoding: .utf8)
        return paths
    }

    private var playStation: Console { ConsoleCatalog.console("ps1")! }

    @Test func readsExtensionsAndFirmwareWithTheirMD5() throws {
        let info = CoreInfo(parsing: try infoText("swanstation"))
        #expect(info.systemID == "playstation")
        #expect(info.extensions.contains("cue") && info.extensions.contains("chd"))
        #expect(info.firmware.map(\.path) == ["psxonpsp660.bin", "scph5500.bin", "scph5501.bin", "scph5502.bin", "ps1_rom.bin"])
        #expect(info.firmware.first { $0.path == "scph5501.bin" }?.md5 == Self.ps1US)
        #expect(info.firmware.allSatisfy { $0.optional })
        // the empty field and the note that names no file are not BIOS
        #expect(info.firmware.allSatisfy { $0.md5 != nil })
    }

    @Test func readsACoreWithoutFirmware() throws {
        let info = CoreInfo(parsing: try infoText("sameboy"))
        #expect(info.extensions == ["gb", "gbc"])
        #expect(info.firmware.isEmpty)
    }

    @Test func playStationBIOSWithTheRightMD5IsFound() throws {
        // The test cannot hold Sony's file: it stands in a file of its own and
        // gives the .info the MD5 of that file
        let standIn = Data("stand-in for a dumped PS1 BIOS".utf8)
        let paths = try setup("swanstation", info: try infoText("swanstation").replacingOccurrences(of: Self.ps1US, with: md5(standIn)))
        try standIn.write(to: paths.bios.appending(path: "scph5501.bin"))

        let status = BIOSChecker(paths: paths).status(for: playStation)
        #expect(status.summary == .found)
        #expect(status.message == "BIOS found")
        #expect(status.files.first { $0.name == "scph5501.bin" }?.state == .found)
    }

    @Test func removedPlayStationBIOSIsNamedAsMissing() throws {
        let paths = try setup("swanstation")
        let status = BIOSChecker(paths: paths).status(for: playStation)
        #expect(status.summary == .missing("scph5501.bin"))
        #expect(status.message == "scph5501.bin is missing")
        #expect(status.isReady == false)
    }

    @Test func aFileWithAnotherMD5IsNotTakenForTheBIOS() throws {
        let paths = try setup("swanstation")
        try Data("not a BIOS".utf8).write(to: paths.bios.appending(path: "scph5501.bin"))
        let status = BIOSChecker(paths: paths).status(for: playStation)
        #expect(status.summary == .wrongFile("scph5501.bin"))
        #expect(status.message == "scph5501.bin is not the expected file")
    }

    @Test func anotherRegionsBIOSIsEnough() throws {
        let standIn = Data("stand-in for a Japanese PS1 BIOS".utf8)
        let paths = try setup("swanstation", info: try infoText("swanstation")
            .replacingOccurrences(of: "8dd7d5296a650fac7319bce665a6a53c", with: md5(standIn)))
        try standIn.write(to: paths.bios.appending(path: "scph5500.bin"))
        #expect(BIOSChecker(paths: paths).status(for: playStation).summary == .found)
    }

    @Test func theRuleNamesTheBIOSBeforeTheInfoFileIsHere() throws {
        let paths = RetroArchPaths(root: try scratchFolder("bios-noinfo"))
        let status = BIOSChecker(paths: paths).status(for: playStation)
        #expect(status.summary == .missing("scph5501.bin"))
    }

    @Test func superNintendoNeedsNoBIOS() throws {
        let paths = try setup("snes9x")
        let status = BIOSChecker(paths: paths).status(for: ConsoleCatalog.console("snes")!)
        #expect(status.summary == .notNeeded)
        #expect(status.message == "No BIOS needed")
        #expect(status.files.map(\.name) == ["BS-X.bin", "STBIOS.bin"])
        #expect(status.files.allSatisfy { !$0.needed })
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CARTOUCHE_PS1_BIOS"] != nil, "set CARTOUCHE_PS1_BIOS to your own scph5501.bin"))
    func aRealDumpIsFound() throws {
        let paths = try setup("swanstation")
        let dump = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CARTOUCHE_PS1_BIOS"]!)
        try FileManager.default.copyItem(at: dump, to: paths.bios.appending(path: "scph5501.bin"))
        #expect(BIOSChecker(paths: paths).status(for: playStation).summary == .found)
    }

    @Test func noDownloadLinkForABIOS() throws {
        let paths = try setup("swanstation")
        try Data("x".utf8).write(to: paths.bios.appending(path: "scph5500.bin"))
        let link = /(?i)(https?:|www\.|\.(com|net|org|io)\b)/
        for console in ConsoleCatalog.all {
            let status = BIOSChecker(paths: paths).status(for: console)
            #expect(status.message.firstMatch(of: link) == nil)
            #expect(status.files.allSatisfy { $0.name.firstMatch(of: link) == nil && $0.description.firstMatch(of: link) == nil })
        }

        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "../../Sources/RetroArchKit").standardized
        let catalog = try String(contentsOf: sources.appending(path: "Resources/Localizable.xcstrings"), encoding: .utf8)
        #expect(catalog.firstMatch(of: link) == nil, "a UI string holds a link")

        // The only addresses in the code: where cores and core info come from,
        // where RetroArch's source is, and the game database and box art,
        // which name games and hold no game file; libretro's netplay lobby and
        // RetroAchievements, which hold no game file either
        let allowed: Set<String> = [
            "http://lobby.libretro.com/",
            "https://retroachievements.org/",
            "https://buildbot.libretro.com/nightly/apple/osx/arm64/latest/",
            "https://buildbot.libretro.com/assets/frontend/info.zip",
            "https://buildbot.libretro.com/stable/",
            "https://github.com/libretro/RetroArch",
            "https://raw.githubusercontent.com/libretro/libretro-database/master/rdb/",
            "https://thumbnails.libretro.com/",
        ]
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for match in text.matches(of: /"(https?:[^"]*)"/) {
                #expect(allowed.contains(String(match.1)), "\(file.lastPathComponent) links to \(match.1)")
            }
        }
    }
}
