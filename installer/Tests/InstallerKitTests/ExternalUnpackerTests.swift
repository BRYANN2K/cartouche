import Foundation
import Testing
@testable import InstallerKit

@Suite("External unpacker")
struct ExternalUnpackerTests {

    @Test("Known helper names are recognized in an Inno file list")
    func helperNames() {
        #expect(ExternalUnpacker.helperName(#"tmp\ISDone.dll"#) == "isdone.dll")
        #expect(ExternalUnpacker.helperName("app/unarc.dll") == "unarc.dll")
        #expect(ExternalUnpacker.helperName("app/cls-srep_x64.exe") == "cls-srep_x64.exe")
        #expect(ExternalUnpacker.helperName("arc.exe") == "arc.exe")
        #expect(ExternalUnpacker.helperName("7z.exe") == "7z.exe")
        #expect(ExternalUnpacker.helperName("app/srep.exe") == "srep.exe")
        #expect(ExternalUnpacker.helperName("app/precomp038.exe") == "precomp038.exe")
        #expect(ExternalUnpacker.helperName("app/xtool.exe") == "xtool.exe")
        #expect(ExternalUnpacker.helperName("app/oo2core_9_win64.dll") == "oo2core_9_win64.dll")
    }

    @Test("Ordinary installer files are not helpers")
    func notHelpers() {
        #expect(ExternalUnpacker.helperName("setup.exe") == nil)
        #expect(ExternalUnpacker.helperName("app/game.exe") == nil)
        #expect(ExternalUnpacker.helperName("app/unins000.exe") == nil)
        #expect(ExternalUnpacker.helperName("app/data.bin") == nil)
        #expect(ExternalUnpacker.helperName("app/dxwebsetup.exe") == nil)
    }

    @Test("Detection from the Inno file list and from files next to setup.exe")
    func detect() throws {
        var report = InnoReport()
        report.files = ["app/game.exe", #"tmp\ISDone.dll"#, #"tmp\unarc.dll"#]
        let inno = try #require(ExternalUnpacker.detect(inno: report, folder: URL(filePath: "/nonexistent")))
        #expect(inno.helpers == ["isdone.dll", "unarc.dll"])

        let folder = try tempFolder(["setup.exe": "MZ", "unarc.dll": "x", "srep.exe": "x"])
        let fromFolder = try #require(ExternalUnpacker.detect(inno: nil, folder: folder))
        #expect(fromFolder.helpers == ["srep.exe", "unarc.dll"])

        #expect(ExternalUnpacker.detect(inno: nil, folder: folder.deletingLastPathComponent()) == nil)
        var plain = InnoReport()
        plain.files = ["app/game.exe"]
        #expect(ExternalUnpacker.detect(inno: plain, folder: folder.deletingLastPathComponent()) == nil)
    }

    @Test("A .arc or .bin part counts only when it opens with the FreeArc signature")
    func freeArcMagic() throws {
        let folder = try tempFolder(["setup.exe": "MZ"])
        let arc = folder.appending(path: "data.arc")
        try Data([0x41, 0x72, 0x43, 0x01, 0, 0, 0]).write(to: arc)
        let bin = folder.appending(path: "data.bin")
        try Data("not an archive".utf8).write(to: bin)
        let found = try #require(ExternalUnpacker.detect(inno: nil, folder: folder))
        #expect(found.helpers == ["data.arc"])
    }

    @Test("The memory share stays under ~3 GB of physical RAM")
    func memoryCap() {
        #expect(ExternalUnpacker.memoryPercent(ramBytes: 4 << 30) == 75)
        #expect(ExternalUnpacker.memoryPercent(ramBytes: 8 << 30) == 37)
        #expect(ExternalUnpacker.memoryPercent(ramBytes: 16 << 30) == 18)
        #expect(ExternalUnpacker.memoryPercent(ramBytes: 64 << 30) == 4)
        #expect(ExternalUnpacker.memoryPercent(ramBytes: 512 << 30) == 2)
    }

    @Test("The profile forces guided mode, a short path, the mapped source and the memory share")
    func profile() {
        var inputs = InstallInputs(runnerID: "r", gameName: "Sample Game: The Long Name", mode: .automatic)
        inputs.applyUnpackerProfile(ramBytes: 16 << 30)
        #expect(inputs.externalUnpacker)
        #expect(inputs.installDir == #"C:\G\SampleGa"#)
        #expect(inputs.shortSource)
        #expect(inputs.mode == .guided)
        #expect(inputs.memoryPercent == 18)
        #expect(!inputs.innoArguments.contains("/VERYSILENT"))
        #expect(!inputs.innoArguments.contains("/SUPPRESSMSGBOXES"))
    }

    @Test("An external-unpacker request never gets the silent switches, even when automatic was asked")
    func neverSilent() {
        var inputs = InstallInputs(runnerID: "r", gameName: "X", mode: .automatic)
        inputs.externalUnpacker = true
        let args = inputs.innoArguments
        #expect(!args.contains("/VERYSILENT"))
        #expect(!args.contains("/SUPPRESSMSGBOXES"))
        #expect(!args.contains("/NOCANCEL"))
    }

    @Test("The setup runs with Wine error channels on and the short temp dir")
    func setupEnvironment() {
        var inputs = InstallInputs(runnerID: "r", gameName: "X")
        inputs.externalUnpacker = true
        let launch = WineInstall.runSetup(URL(filePath: "/S/setup.exe"), runner: sampleRunner,
                                          prefix: URL(filePath: "/P/pfx"), inputs: inputs, base: [:])
        #expect(launch.environment["WINEDEBUG"] == "err+all,+seh,+loaddll,+process")
        #expect(launch.environment["TEMP"] == #"C:\T"#)
        #expect(launch.environment["TMP"] == #"C:\T"#)
    }

    @Test("Ordinary installs get the diagnostics too, but keep their own temp dir")
    func ordinaryEnvironment() {
        let inputs = InstallInputs(runnerID: "r", gameName: "X")
        let launch = WineInstall.runSetup(URL(filePath: "/S/setup.exe"), runner: sampleRunner,
                                          prefix: URL(filePath: "/P/pfx"), inputs: inputs, base: [:])
        #expect(launch.environment["WINEDEBUG"] == "err+all,+seh,+loaddll,+process")
        #expect(launch.environment["TEMP"] == nil)
        #expect(launch.environment["TMP"] == nil)
    }

    @Test("C:\\T is made inside the prefix's drive_c")
    func makeTemp() throws {
        let prefix = try tempFolder([:])
        try WineInstall.makeTemp(prefix: prefix)
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: prefix.appending(path: "drive_c/T").path, isDirectory: &isDir))
        #expect(isDir.boolValue)
    }

    @Test("Saved inputs from before the field existed decode as no external unpacker")
    func decodesWithoutField() throws {
        let json = """
        {"runnerID":"r","installDir":"C:\\\\Games\\\\X","mode":"guided","log":"C:\\\\installer.log",
         "verifyFirst":false,"shortSource":false,"language":"en"}
        """
        let inputs = try JSONDecoder().decode(InstallInputs.self, from: Data(json.utf8))
        #expect(!inputs.externalUnpacker)
        #expect(inputs.mode == .guided)
    }
}
