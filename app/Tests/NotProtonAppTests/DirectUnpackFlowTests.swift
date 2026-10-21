import Foundation
import InstallerKit
import Testing

@testable import NotProtonApp

// An installer with an external unpacker, unpacked directly: the fake Wine script plays the
// driver (each call unpacks one part into the install dir), a fake innoextract produces the tmp
// helpers and the app section, and the shipped manifest verifies what landed. setup.exe stays a
// trap: the direct path must never run it.
struct FakeUnpack {
    let work: URL
    let runners: URL
    let installs: URL
    let source: URL
    let calls: URL
    let trap: URL
    let tool: URL
    let driver: URL
    let runner: Runner

    // behavior: "ok" writes the game, "fail" the decompressor's memory error, "missing" a
    // part-not-found, "hang" sleeps so the test can stop it. badManifest makes the shipped
    // manifest not match what was written.
    init(_ label: String, behavior: String = "ok", badManifest: Bool = false) throws {
        work = try scratchDirectory(label)
        runners = work.appending(path: "runners")
        installs = work.appending(path: "installs")
        source = work.appending(path: "Downloads/Sample Game")
        calls = work.appending(path: "calls.log")
        trap = work.appending(path: "trap-fired")
        tool = work.appending(path: "innoextract")
        driver = work.appending(path: DirectUnpack.driverName)
        runner = try fakeRunner(in: runners)

        let fm = FileManager.default
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("#!/bin/sh\ntouch '\(trap.path)'\n".utf8).write(to: source.appending(path: "setup.exe"))
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.appending(path: "setup.exe").path)
        for name in ["data-01.bin", "data-02.bin"] {
            try Data([0x41, 0x72, 0x43, 0x01, 0, 0, 0, 0]).write(to: source.appending(path: name))
        }
        try Data("MZ".utf8).write(to: driver)

        // What the driver leaves behind for both parts; the manifest has to match exactly.
        let expected = Data("content-data-01.bincontent-data-02.bin".utf8)
        let expectedSum = badManifest ? "00000000000000000000000000000000"
            : try { () throws -> String in
                let probe = work.appending(path: "expected.bin")
                try expected.write(to: probe)
                return try Checksums.md5(of: probe)
            }()

        let root = SupportPaths.clonedRoot(forBuild: runner.id, runners: runners)
        let server = root.appending(path: "bin/wineserver")
        try fm.createDirectory(at: server.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\necho \"wineserver $*\" >> '\(calls.path)'\nexit 0\n".utf8).write(to: server)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: server.path)

        // -s -I <section> -d <dir> <setup>: only the asked section is produced.
        try Data("""
        #!/bin/sh
        echo "innoextract $*" >> '\(calls.path)'
        dir=""; section=""; prev=""
        for a in "$@"; do
          case "$prev" in
            -I) section="$a";;
            -d) dir="$a";;
          esac
          prev="$a"
        done
        mkdir -p "$dir/$section"
        case "$section" in
        tmp)
          printf 'x' > "$dir/$section/unarc.dll"
          printf 'x' > "$dir/$section/cls-srep.dll"
          printf 'x' > "$dir/$section/cls-srep_x64.exe"
          printf 'cfg' > "$dir/$section/arc.ini"
          printf '%s\\n' 'TempPath={app}\\TEMPS' 'FreeMEM=200' > "$dir/$section/CLS.ini"
          ;;
        app)
          mkdir -p "$dir/$section/_Redist"
          printf '%s *..\\\\game.exe\\n' '\(expectedSum)' > "$dir/$section/_Redist/game.md5"
          printf 'x' > "$dir/$section/_Redist/dxwebsetup.exe"
          ;;
        esac
        exit 0
        """.utf8).write(to: tool)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)

        let wine = root.appending(path: "lib/wine/x86_64-unix/wine")
        let script = """
        #!/bin/sh
        printf '%s %s TEMP=%s\\n' "$(uname -m)" "$*" "$TEMP" >> '\(calls.path)'
        if [ "$1" = wineboot ]; then mkdir -p "$WINEPREFIX/drive_c/users/crossover/Temp"; exit 0; fi
        case "$1" in
        *unarc-driver.exe)
          dir=""; part=""; prev=""
          for a in "$@"; do
            case "$prev" in --) part="$a";; esac
            case "$a" in -dp*) dir="${a#-dp}";; esac
            prev="$a"
          done
          game="$WINEPREFIX/drive_c/$(echo "${dir#C:\\\\}" | tr '\\\\' '/')"
          case '\(behavior)' in
          hang) mkdir -p "$game"; sleep 30; exit 0;;
          fail) printf 'filename data.bin\\nerror 0 0 memory\\nresult -11\\n'; exit 5;;
          missing) printf 'error 0 0 source file does not exist\\nresult -6\\n'; exit 5;;
          esac
          mkdir -p "$game"
          printf 'content-%s' "${part#S:\\\\}" >> "$game/game.exe"
          printf 'filename %s\\nresult 0\\n' "$part"
          exit 0;;
        esac
        exit 0
        """
        try Data(script.utf8).write(to: wine)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wine.path)
    }

    func engine(winetricks: VerbLog, freeSpace: Int64 = .max, driverMissing: Bool = false) -> InstallEngine {
        var engine = InstallEngine(installs: installs, runners: runners,
                                   registry: { [runner] in RunnerRegistry(runners: [runner]) })
        engine.environment = ["PATH": "/usr/bin:/bin"]
        engine.policy = InstallRun.Policy(interval: 0.2, stuckAfter: 300)
        engine.keepAwake = false
        engine.innoextract = { [tool] in tool.path(percentEncoded: false) }
        engine.toolRunner = { ProcessToolRunner(timeout: 30) }
        engine.unpackerDriver = { [driver] in driverMissing ? nil : driver }
        engine.freeSpace = { _ in freeSpace }
        engine.winetricks = { verbs, _, _, _ in
            winetricks.add(verbs)
            return InstallRun(InstallLaunch(executable: "/bin/sh", arguments: ["-c", "exit 0"], environment: [:]))
        }
        return engine
    }

    func request() -> InstallRequest {
        let parts = ["data-01.bin", "data-02.bin"].map { source.appending(path: $0) }
        var request = InstallRequest(
            setup: source.appending(path: "setup.exe"), source: source, name: "Sample Game",
            appID: nil, gogID: nil, expectedBytes: 10_000, installerBytes: 100,
            installerFiles: [source.appending(path: "setup.exe")] + parts, manifest: nil)
        request.directUnpack = DirectUnpackPlan(
            parts: parts, helpers: ["CLS.ini", "arc.ini", "cls-srep.dll", "cls-srep_x64.exe", "unarc.dll"],
            unarcModule: "unarc.dll", arcConfig: "arc.ini", clsConfig: "CLS.ini",
            manifestPath: "_Redist/game.md5")
        return request
    }

    func inputs() -> InstallInputs {
        var inputs = InstallInputs(runnerID: runner.id, gameName: "Sample Game")
        inputs.applyUnpackerProfile(ramBytes: 16 << 30)
        return inputs
    }

    func calledWith() -> [String] {
        ((try? String(contentsOf: calls, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }
}

@MainActor
@Suite("Direct unpack flow", .serialized, .enabled(if: rosettaAvailable, "Rosetta is not installed, so arch -x86_64 cannot run"))
struct DirectUnpackFlowTests {

    @Test("Both parts unpack through the driver, the manifest verifies, setup never runs")
    func success() async throws {
        let fake = try FakeUnpack("unpack-ok")
        let verbs = VerbLog()
        let center = InstallCenter(engine: fake.engine(winetricks: verbs), notifier: RecordingNotifier())
        let job = InstallJob(request: fake.request(), inputs: fake.inputs())
        center.sheet.show(job)
        center.enqueue(job)
        #expect(await waitFor { job.phase == .choosing || job.phase == .failed })
        #expect(job.phase == .choosing)

        let calls = fake.calledWith()
        let drivers = calls.filter { $0.contains("unarc-driver.exe") }
        #expect(drivers.count == 2)
        #expect(drivers[0].contains(#"S:\data-01.bin"#))
        #expect(drivers[1].contains(#"S:\data-02.bin"#))
        #expect(drivers[0].contains(#"-dpC:\G\SampleGa"#))
        #expect(drivers.allSatisfy { $0.hasSuffix(#"TEMP=C:\T"#) })
        #expect(!calls.contains { $0.contains("setup.exe /DIR=") })
        #expect(!FileManager.default.fileExists(atPath: fake.trap.path))

        let folder = try #require(job.folder)
        let helpers = folder.prefix.appending(path: "drive_c/U")
        #expect(FileManager.default.fileExists(atPath: helpers.appending(path: DirectUnpack.driverName).path))
        let ini = try String(contentsOf: helpers.appending(path: "CLS.ini"), encoding: .utf8)
        #expect(ini.contains(#"TempPath=C:\T\TEMPS"#))
        #expect(!ini.contains("{app}"))

        let game = folder.prefix.appending(path: "drive_c/G/SampleGa")
        #expect(try String(contentsOf: game.appending(path: "game.exe"), encoding: .utf8) == "content-data-01.bincontent-data-02.bin")
        #expect(FileManager.default.fileExists(atPath: game.appending(path: "_Redist/dxwebsetup.exe").path))
        #expect(job.candidates.map { ($0.path as NSString).lastPathComponent } == ["game.exe"])
        #expect(verbs.calls == [["d3dx9"]])
        #expect(FileManager.default.fileExists(atPath: folder.root.appending(path: "unpack-1-data-01.bin.log").path))
    }

    @Test("A manifest that does not match fails as damaged")
    func checksumMismatch() async throws {
        let fake = try FakeUnpack("unpack-badsum", badManifest: true)
        let center = InstallCenter(engine: fake.engine(winetricks: VerbLog()), notifier: RecordingNotifier())
        let job = InstallJob(request: fake.request(), inputs: fake.inputs())
        center.sheet.show(job)
        center.enqueue(job)
        #expect(await waitFor { job.phase == .failed || job.phase == .choosing })
        #expect(job.phase == .failed)
        #expect(job.diagnosis?.kind == .damagedFile)
    }

    @Test("A part the unpacker cannot open is a missing part")
    func missingPart() async throws {
        let fake = try FakeUnpack("unpack-missing", behavior: "missing")
        let center = InstallCenter(engine: fake.engine(winetricks: VerbLog()), notifier: RecordingNotifier())
        let job = InstallJob(request: fake.request(), inputs: fake.inputs())
        center.sheet.show(job)
        center.enqueue(job)
        #expect(await waitFor { job.phase == .failed })
        #expect(job.diagnosis?.kind == .missingPart)
        #expect(job.diagnosis?.detail?.contains("does not exist") == true)
    }

    @Test("A decompressor error reports the log's error line")
    func logTailFailure() async throws {
        let fake = try FakeUnpack("unpack-fail", behavior: "fail")
        let center = InstallCenter(engine: fake.engine(winetricks: VerbLog()), notifier: RecordingNotifier())
        let job = InstallJob(request: fake.request(), inputs: fake.inputs())
        center.sheet.show(job)
        center.enqueue(job)
        #expect(await waitFor { job.phase == .failed })
        #expect(job.diagnosis?.kind == .decompression)
        #expect(job.diagnosis?.detail == "error 0 0 memory")
    }

    @Test("Stop kills only this prefix's processes and removes the attempt")
    func cancellation() async throws {
        let fake = try FakeUnpack("unpack-hang", behavior: "hang")
        let center = InstallCenter(engine: fake.engine(winetricks: VerbLog()), notifier: RecordingNotifier())
        let job = InstallJob(request: fake.request(), inputs: fake.inputs())
        center.sheet.show(job)
        center.enqueue(job)
        #expect(await waitFor { job.phase == .installing && fake.calledWith().contains { $0.contains("unarc-driver.exe") } })
        let folder = try #require(job.folder)
        center.stop(job)
        #expect(await waitFor { job.phase == .stopped })
        #expect(fake.calledWith().contains { $0 == "wineserver -k" })
        #expect(!FileManager.default.fileExists(atPath: folder.root.path))
    }

    @Test("Not enough space fails before Wine ever runs")
    func diskFull() async throws {
        let fake = try FakeUnpack("unpack-full")
        let center = InstallCenter(engine: fake.engine(winetricks: VerbLog(), freeSpace: 1), notifier: RecordingNotifier())
        let job = InstallJob(request: fake.request(), inputs: fake.inputs())
        center.sheet.show(job)
        center.enqueue(job)
        #expect(await waitFor { job.phase == .failed })
        #expect(job.problem?.contains("free space") == true)
        #expect(!fake.calledWith().contains { $0.contains("unarc-driver.exe") })
    }

    @Test("A build without the driver fails clearly instead of running setup")
    func driverMissing() async throws {
        let fake = try FakeUnpack("unpack-nodriver")
        let center = InstallCenter(engine: fake.engine(winetricks: VerbLog(), driverMissing: true), notifier: RecordingNotifier())
        let job = InstallJob(request: fake.request(), inputs: fake.inputs())
        center.sheet.show(job)
        center.enqueue(job)
        #expect(await waitFor { job.phase == .failed })
        #expect(job.problem?.contains(DirectUnpack.driverName) == true)
        #expect(!FileManager.default.fileExists(atPath: fake.trap.path))
    }
}
