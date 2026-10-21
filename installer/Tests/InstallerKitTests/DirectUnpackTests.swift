import Foundation
import Testing
@testable import InstallerKit

private let arcMagic = Data([0x41, 0x72, 0x43, 0x01, 0, 0, 0, 0])

private func freeArcPart(_ dir: URL, _ name: String) throws -> URL {
    let url = dir.appending(path: name)
    try arcMagic.write(to: url)
    return url
}

// The file list a FreeArc/CLS set gives innoextract --list: helpers under tmp\, the game under app\.
private func clsList(extra: [String] = []) -> InnoReport {
    var report = InnoReport()
    report.files = [
        #"tmp\ISDone.dll"#, #"tmp\unarc.dll"#, #"tmp\cls-srep.dll"#, #"tmp\cls-srep_x86.exe"#,
        #"tmp\cls-srep_x64.exe"#, #"tmp\xtool.exe"#, #"tmp\arc.ini"#, #"tmp\CLS.ini"#,
        #"app\_Redist\dxwebsetup.exe"#, #"app\_Redist\game.md5"#, #"app\readme.txt"#,
    ] + extra
    return report
}

@Suite("Direct unpack plan")
struct DirectUnpackTests {

    @Test("A FreeArc/CLS set is planned")
    func planPositive() throws {
        let dir = try tempFolder(["setup.exe": "MZ"])
        _ = try freeArcPart(dir, "data-01.bin"); _ = try freeArcPart(dir, "data-02.bin")
        let plan = try #require(DirectUnpack.plan(inno: clsList(), scan: PartScanner.scan(dir)))
        #expect(plan.parts.map(\.lastPathComponent) == ["data-01.bin", "data-02.bin"])
        #expect(plan.unarcModule == "unarc.dll")
        #expect(plan.arcConfig == "arc.ini")
        #expect(plan.clsConfig == "CLS.ini")
        #expect(plan.manifestPath == "_Redist/game.md5")
        #expect(plan.helpers.contains("unarc.dll"))
    }

    @Test("A plain Inno installer is not planned")
    func planPlainInno() throws {
        let dir = try tempFolder(["setup.exe": "MZ", "data-1.bin": "a"])
        var report = InnoReport()
        report.files = ["app/game.exe", "app/data.pak"]
        let scan = try PartScanner.scan(dir)
        #expect(DirectUnpack.plan(inno: report, scan: scan) == nil)
    }

    @Test("The signature needs the unpacker module, a CLS helper and its config")
    func planNeedsThePattern() throws {
        let dir = try tempFolder(["setup.exe": "MZ"])
        _ = try freeArcPart(dir, "data-01.bin")
        let scan = try PartScanner.scan(dir)

        var noUnarc = clsList()
        noUnarc.files.removeAll { $0.hasSuffix("unarc.dll") }
        #expect(DirectUnpack.plan(inno: noUnarc, scan: scan) == nil)

        var noCls = clsList()
        noCls.files.removeAll { $0.lowercased().contains("cls-") || $0.lowercased().contains("cls.ini") }
        #expect(DirectUnpack.plan(inno: noCls, scan: scan) == nil)

        var noArc = clsList()
        noArc.files.removeAll { $0.hasSuffix("arc.ini") }
        #expect(DirectUnpack.plan(inno: noArc, scan: scan) == nil)

        var passworded = clsList()
        passworded.passworded = true
        #expect(DirectUnpack.plan(inno: passworded, scan: scan) == nil)
    }

    @Test("A .bin part without the FreeArc signature keeps the setup path")
    func planRejectsPlainBin() throws {
        let dir = try tempFolder(["setup.exe": "MZ", "data-01.bin": "just data", "data-02.bin": "more data"])
        let scan = try PartScanner.scan(dir)
        #expect(DirectUnpack.plan(inno: clsList(), scan: scan) == nil)
    }

    @Test("A .bin file outside the numbering keeps the setup path")
    func planRejectsStrayBin() throws {
        let dir = try tempFolder(["setup.exe": "MZ", "datablob.bin": "x"])
        _ = try freeArcPart(dir, "data-01.bin")
        let scan = try PartScanner.scan(dir)
        #expect(DirectUnpack.plan(inno: clsList(), scan: scan) == nil)
    }

    @Test("No parts means nothing to unpack")
    func planNeedsParts() throws {
        let dir = try tempFolder(["setup.exe": "MZ"])
        let scan = try PartScanner.scan(dir)
        #expect(DirectUnpack.plan(inno: clsList(), scan: scan) == nil)
    }

    @Test("The {app} placeholder becomes the temp dir, byte-exact")
    func patchesClsIni() throws {
        let ini = """
        [Settings]
        TempPath={app}\\TEMPS
        Other={app}
        FreeMEM=200
        """.data(using: .utf8)!
        let patched = try #require(String(data: DirectUnpack.patchedTempConfig(ini, tempDir: #"C:\T"#), encoding: .utf8))
        #expect(patched.contains(#"TempPath=C:\T\TEMPS"#))
        #expect(patched.contains(#"Other=C:\T"#))
        #expect(!patched.contains("{app}"))
        #expect(patched.contains("FreeMEM=200"))
    }

    @Test("patchConfig also applies the memory and thread limits")
    func patchConfigLimits() throws {
        let dir = try tempFolder(["U/CLS.ini": "[Srep]\nTempPath={app}\nMemory=60%-2048m\n[mtx]\nThreads=100p\n"])
        let ini = dir.appending(path: "U/CLS.ini")
        #expect(try DirectUnpack.patchConfig(at: ini, tempDir: #"C:\T"#, memoryPercent: 18, threads: 2))
        let text = try String(contentsOf: ini, encoding: .utf8)
        #expect(text.contains(#"TempPath=C:\T"#))
        #expect(text.contains("Memory=18%"))
        #expect(text.contains("Threads=2"))
        #expect(try DirectUnpack.patchConfig(at: dir.appending(path: "U/missing.ini"), tempDir: #"C:\T"#, memoryPercent: nil, threads: nil) == false)
    }

    @Test("FreeArcExtract's arguments keep the proven order")
    func driverArguments() {
        let args = DirectUnpack.arguments(installDir: #"C:\G\CarX"#, tempDir: #"C:\T"#, config: #"C:\U\arc.ini"#)
        #expect(args == ["x", "-o+", #"-dpC:\G\CarX"#, #"-wC:\T"#, #"-cfgC:\U\arc.ini"#])
    }

    @Test("The driver's launch is the prefixed driver exe over the mapped source drive")
    func driverLaunch() {
        var inputs = InstallInputs(runnerID: "r", gameName: "X")
        inputs.applyUnpackerProfile()
        let plan = DirectUnpackPlan(parts: [URL(filePath: "/S/data-01.bin")], helpers: [], unarcModule: "unarc.dll",
                                    arcConfig: "arc.ini", clsConfig: "CLS.ini", manifestPath: nil)
        let launch = WineInstall.runUnpackDriver(part: plan.parts[0], plan: plan, installDir: #"C:\G\X"#,
                                                 runner: sampleRunner, prefix: URL(filePath: "/P/pfx"),
                                                 inputs: inputs, base: [:])
        #expect(launch.arguments.contains(#"C:\U\unarc-driver.exe"#))
        #expect(launch.arguments.contains(#"S:\data-01.bin"#))
        #expect(launch.environment["WINEDEBUG"] == "-all")
        #expect(launch.environment["TEMP"] == #"C:\T"#)
        #expect(launch.environment["MVK_CONFIG_LOG_LEVEL"] == "0")
        #expect(launch.currentDirectory?.path(percentEncoded: false) == "/P/pfx/drive_c/U")
    }

    @Test("A decompressor memory error maps to the memory retry fixes")
    func diagnoseMemory() {
        let log = "filename data.bin\nerror 0 0 memory\nresult -11\n"
        let d = DirectUnpack.diagnose(status: 245, log: log)
        #expect(d.kind == .decompression)
        #expect(d.fixes.contains(.lessMemory))
    }

    @Test("A missing part is its own diagnosis")
    func diagnoseMissingPart() {
        let log = "error 0 0 source file does not exist\nresult -6\n"
        let d = DirectUnpack.diagnose(status: 250, log: log)
        #expect(d.kind == .missingPart)
    }

    @Test("A full disk is its own diagnosis")
    func diagnoseDiskFull() {
        let log = "error 0 0 not enough disk space\nresult -6\n"
        #expect(DirectUnpack.diagnose(status: 250, log: log).kind == .diskSpace)
    }

    @Test("The driver failing to load the module is a runner problem")
    func diagnoseDriver() {
        let log = "cannot load unarc.dll: 126\n"
        #expect(DirectUnpack.diagnose(status: 3, log: log).kind == .setupFailed)
    }

    @Test("innoextract extracts only the asked section into its dir")
    func extractSection() throws {
        let dir = try tempFolder(["setup.exe": "MZ"])
        let log = dir.appending(path: "calls.log")
        let tool = dir.appending(path: "innoextract")
        try executable(tool, """
        #!/bin/sh
        echo "$*" >> "\(log.path(percentEncoded: false))"
        mkdir -p "$5/$3"
        """)
        try Innoextract.extract(setup: dir.appending(path: "setup.exe"), section: "tmp", into: dir.appending(path: "out"),
                                tool: tool.path(percentEncoded: false), runner: ProcessToolRunner())
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: "out/tmp").path(percentEncoded: false), isDirectory: &isDir))
        #expect(isDir.boolValue)
        let calls = try String(contentsOf: log, encoding: .utf8)
        #expect(calls.contains("-s -I tmp -d"))
    }

    @Test("A section that does not come out is an error with the tool's tail")
    func extractMissing() throws {
        let dir = try tempFolder(["setup.exe": "MZ"])
        let tool = dir.appending(path: "innoextract")
        try executable(tool, "#!/bin/sh\necho 'stream error on file' >&2\nexit 1\n")
        do {
            try Innoextract.extract(setup: dir.appending(path: "setup.exe"), section: "tmp", into: dir.appending(path: "out"),
                                    tool: tool.path(percentEncoded: false), runner: ProcessToolRunner())
            Issue.record("expected SectionMissing")
        } catch let missing as Innoextract.SectionMissing {
            #expect(missing.section == "tmp")
        }
    }
}
