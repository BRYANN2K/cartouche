import Foundation
import InstallerKit
import Testing

@testable import NotProtonApp

// A runner whose Wine is a script: it records how it was called, makes the
// prefix on wineboot, and plays an installer that writes files and a log.
// Nothing here is a Windows program; the dropped folder's setup.exe is a trap
// that leaves a marker if anything executes it.
struct FakeInstall {
    let work: URL
    let runners: URL
    let installs: URL
    let source: URL
    let calls: URL
    let trap: URL
    let runner: Runner

    // behavior: "ok" writes a game and a clean log, "unarc" writes the decompression error, "hang" sleeps.
    // withManifest adds a sparse 400 MB part and a real checksums.md5 for it.
    init(_ label: String, behavior: String = "ok", withManifest: Bool = false) throws {
        work = try scratchDirectory(label)
        runners = work.appending(path: "runners")
        installs = work.appending(path: "installs")
        source = work.appending(path: "Downloads/Sample Game Installer")
        calls = work.appending(path: "calls.log")
        trap = work.appending(path: "trap-fired")
        runner = try fakeRunner(in: runners)

        let fm = FileManager.default
        try fm.createDirectory(at: source.appending(path: "MD5"), withIntermediateDirectories: true)
        let trapScript = "#!/bin/sh\ntouch '\(trap.path)'\n"
        var names = ["setup.exe", "data-01.bin", "data-02.bin"]
        if withManifest {
            let big = source.appending(path: "data-03.bin")
            fm.createFile(atPath: big.path, contents: nil)
            try FileHandle(forWritingTo: big).truncateFile(atOffset: 400 << 20)
            names.append("data-03.bin")
        }
        for name in names {
            if !(withManifest && name == "data-03.bin") {
                try Data(trapScript.utf8).write(to: source.appending(path: name))
            }
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.appending(path: name).path)
        }
        var sums = "; checksums\n"
        if withManifest {
            for name in names {
                sums += "\(try Checksums.md5(of: source.appending(path: name))) *..\\\(name)\n"
            }
        }
        try Data(sums.utf8).write(to: source.appending(path: "MD5/checksums.md5"))

        let root = SupportPaths.clonedRoot(forBuild: runner.id, runners: runners)
        let server = root.appending(path: "bin/wineserver")
        try fm.createDirectory(at: server.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: server)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: server.path)

        let wine = root.appending(path: "lib/wine/x86_64-unix/wine")
        let script = """
        #!/bin/sh
        echo "$(uname -m) $* TEMP=$TEMP" >> '\(calls.path)'
        if [ "$1" = wineboot ]; then mkdir -p "$WINEPREFIX/drive_c/users/crossover/Temp"; exit 0; fi
        dir=""
        for a in "$@"; do case "$a" in /DIR=*) dir="${a#/DIR=}";; esac; done
        game="$WINEPREFIX/drive_c/$(echo "${dir#C:\\\\}" | tr '\\\\' '/')"
        case '\(behavior)' in
        hang) mkdir -p "$game"; sleep 30; exit 0;;
        spawn)
          mkdir -p "$game"; head -c 300000 /dev/zero > "$game/game.exe"
          /bin/sh -c 'sleep 2; touch "$WINEPREFIX/../helper-done"' &
          printf 'Starting the installation process.\\nInstallation process succeeded.\\nLog closed.\\n' > "$WINEPREFIX/drive_c/installer.log"
          sleep 0.6
          exit 0;;
        unarc)
          printf 'Starting the installation process.\\nAn error occurred while unpacking: Unarc.dll returned an error code: -11\\nERROR: archive data corrupted (decompression fails)\\n' > "$WINEPREFIX/drive_c/installer.log"
          exit 0;;
        esac
        mkdir -p "$game/_Redist"
        for i in 1 2 3 4; do head -c 300000 /dev/zero >> "$game/game.exe"; sleep 0.2; done
        head -c 2000 /dev/zero > "$game/unins000.exe"
        head -c 1000 /dev/zero > "$game/_Redist/dxwebsetup.exe"
        head -c 1000 /dev/zero > "$game/_Redist/dotNetFx40_Full_setup.exe"
        printf 'Starting the installation process.\\nInstallation process succeeded.\\nLog closed.\\n' > "$WINEPREFIX/drive_c/installer.log"
        exit 0
        """
        try Data(script.utf8).write(to: wine)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wine.path)
    }

    var verbs: VerbLog { VerbLog() }

    func engine(winetricks: VerbLog, stuckAfter: TimeInterval = 300) -> InstallEngine {
        var engine = InstallEngine(installs: installs, runners: runners, registry: { [runner] in RunnerRegistry(runners: [runner]) })
        engine.environment = ["PATH": "/usr/bin:/bin"]
        engine.policy = InstallRun.Policy(interval: 0.2, stuckAfter: stuckAfter)
        engine.keepAwake = false
        engine.winetricks = { verbs, _, _, _ in
            winetricks.add(verbs)
            return InstallRun(InstallLaunch(executable: "/bin/sh", arguments: ["-c", "exit 0"], environment: [:]))
        }
        return engine
    }

    func request(manifest: Bool = false) -> InstallRequest {
        var files = ["setup.exe", "data-01.bin", "data-02.bin", "MD5/checksums.md5"]
        if manifest { files.append("data-03.bin") }
        let urls = files.map { source.appending(path: $0) }
        let parsed = manifest ? try? Checksums.parse(source.appending(path: "MD5/checksums.md5")) : nil
        return InstallRequest(setup: source.appending(path: "setup.exe"), source: source, name: "Sample Game", appID: 632_470,
                              gogID: nil, expectedBytes: 1_200_000, installerBytes: 10_000, installerFiles: urls, manifest: parsed ?? nil)
    }

    func calledWith() -> [String] {
        ((try? String(contentsOf: calls, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }
}

final class VerbLog: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [[String]] = []
    func add(_ verbs: [String]) { lock.withLock { all.append(verbs) } }
    var calls: [[String]] { lock.withLock { all } }
}

@MainActor
final class RecordingNotifier: InstallNotifying {
    var posted: [String] = []
    func installed(name: String, job: UUID) { posted.append(String(localized: "\(name) is installed")) }
    func failed(name: String, job: UUID) { posted.append("failed \(name)") }
}

@MainActor
func waitFor(_ timeout: TimeInterval = 20, _ condition: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while !condition() && Date() < end { try? await Task.sleep(for: .milliseconds(50)) }
    return condition()
}

let rosettaAvailable: Bool = {
    let p = Process()
    p.executableURL = URL(filePath: "/usr/bin/arch")
    p.arguments = ["-x86_64", "/usr/bin/true"]
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return false }
    p.waitUntilExit()
    return p.terminationStatus == 0
}()

@MainActor
@Suite("Install flow", .serialized, .enabled(if: rosettaAvailable, "Rosetta is not installed, so arch -x86_64 cannot run"))
struct InstallFlowTests {

    @Test("A background install: the sheet closes, the activity shows progress, the notification says it is installed")
    func backgroundInstall() async throws {
        let fake = try FakeInstall("flow-ok")
        let verbs = VerbLog()
        let notifier = RecordingNotifier()
        let center = InstallCenter(engine: fake.engine(winetricks: verbs), notifier: notifier)
        let job = InstallJob(request: fake.request(), inputs: InstallInputs(runnerID: fake.runner.id, gameName: "Sample Game", language: "en"))
        center.isSheetPresented = true
        center.sheet.show(job)
        center.enqueue(job)
        center.continueInBackground()
        #expect(!center.isSheetPresented)

        var fractions: [Double] = []
        let finished = await waitFor {
            if let a = center.activity { fractions.append(a.fraction) }
            return job.phase == .choosing || job.phase == .failed
        }
        #expect(finished)
        #expect(job.phase == .choosing)
        #expect(fractions.contains { $0 > 0 })
        #expect(fractions == fractions.sorted())
        #expect(center.activity == nil)
        #expect(notifier.posted == ["Sample Game is installed"])

        // Rosetta, the runner's loader, setup.exe with the Inno options; wineboot first.
        let calls = fake.calledWith()
        #expect(calls.first == "x86_64 wineboot -u TEMP=")
        #expect(calls.dropFirst().first == "x86_64 \(fake.source.appending(path: "setup.exe").path) /DIR=C:\\Games\\Sample Game /NORESTART /LOG=C:\\installer.log /LANG=en TEMP=")
        #expect(calls.count == 2)
        #expect(!FileManager.default.fileExists(atPath: fake.trap.path))

        // The redistributables were not run; winetricks installed the verbs, one per call, .NET excepted.
        #expect(verbs.calls == [["d3dx9"]])
        #expect(job.runtimeSteps.map(\.status) == [.installed])
        #expect(job.candidates.map { ($0.path as NSString).lastPathComponent } == ["game.exe"])
    }

    @Test("A sheet left open moves to the exe step without a notification")
    func foregroundInstall() async throws {
        let fake = try FakeInstall("flow-fg")
        let notifier = RecordingNotifier()
        let center = InstallCenter(engine: fake.engine(winetricks: VerbLog()), notifier: notifier)
        let job = InstallJob(request: fake.request(), inputs: InstallInputs(runnerID: fake.runner.id, gameName: "Sample Game"))
        center.isSheetPresented = true
        center.sheet.show(job)
        center.enqueue(job)
        #expect(center.sheet.step == .installing)
        #expect(await waitFor { job.phase == .choosing })
        #expect(center.sheet.step == .chooseExe)
        #expect(notifier.posted.isEmpty)
    }

    @Test("Finishing writes the record, the launcher and the Steam shortcut; the installer files stay until Delete is confirmed")
    func finishAndCleanup() async throws {
        let fake = try FakeInstall("flow-finish")
        let center = InstallCenter(engine: fake.engine(winetricks: VerbLog()), notifier: RecordingNotifier())
        let job = InstallJob(request: fake.request(), inputs: InstallInputs(runnerID: fake.runner.id, gameName: "Sample Game"))
        center.sheet.show(job)
        center.enqueue(job)
        #expect(await waitFor { job.phase == .choosing })

        let userdata = fake.work.appending(path: "Steam/userdata")
        try FileManager.default.createDirectory(at: userdata.appending(path: "12345/config"), withIntermediateDirectories: true)
        let steam = SteamShortcuts(userdata: userdata, steamIsRunning: { false })
        let exe = try #require(job.candidates.first?.path)
        let outcome = try await center.engine.finish(job, exe: URL(filePath: exe), showInSteam: true, steam: steam)
        #expect(outcome == .added)
        #expect(job.phase == .ready)
        #expect(center.sheet.step == .ready)

        let game = try #require(InstalledGames.all(in: fake.installs).first)
        #expect(game.name == "Sample Game")
        #expect(game.appID == 632_470)
        #expect(game.steamShortcut)
        let launcher = try String(contentsOf: game.launcher, encoding: .utf8)
        #expect(launcher.contains("export WINEPREFIX="))
        let vdf = try Data(contentsOf: userdata.appending(path: "12345/config/shortcuts.vdf"))
        let entry = try #require(BinaryVDF.parse(vdf)?.first?.1)
        guard case .map(let shortcuts) = entry else { Issue.record("no shortcuts map"); return }
        #expect(shortcuts.first?.1.string("appname") == "Sample Game")
        #expect(shortcuts.first?.1.string("exe") == "\"\(game.launcher.path)\"")

        // Cleanup is never automatic.
        for file in job.request.installerFiles { #expect(FileManager.default.fileExists(atPath: file.path)) }
        let trashed = TrashLog()
        center.sheet.cleaner = InstallerCleanup(trash: { trashed.add($0) }, home: fake.work)
        center.sheet.requestCleanup()
        #expect(center.sheet.cleanup == .confirming)
        #expect(trashed.urls.isEmpty)
        center.sheet.confirmCleanup()
        #expect(trashed.urls.map(\.lastPathComponent) == ["setup.exe", "data-01.bin", "data-02.bin", "checksums.md5"])
        #expect(center.sheet.cleanup == .done(10_000))
    }

    @Test("A stuck installer is reported, and Stop ends it and removes the unfinished attempt")
    func stuckAndStop() async throws {
        let fake = try FakeInstall("flow-stuck", behavior: "hang")
        let center = InstallCenter(engine: fake.engine(winetricks: VerbLog(), stuckAfter: 1), notifier: RecordingNotifier())
        let job = InstallJob(request: fake.request(), inputs: InstallInputs(runnerID: fake.runner.id, gameName: "Sample Game"))
        center.sheet.show(job)
        center.enqueue(job)
        #expect(await waitFor { job.isStuck })
        #expect(center.activity?.stuck == true)
        let folder = try #require(job.folder)
        center.sheet.stop()
        #expect(await waitFor { job.phase == .stopped })
        #expect(!FileManager.default.fileExists(atPath: folder.root.path))
    }

    @Test("A decompression error offers the retries, and a retry runs again with the changed inputs")
    func failureAndRetry() async throws {
        let fake = try FakeInstall("flow-unarc", behavior: "unarc")
        let center = InstallCenter(engine: fake.engine(winetricks: VerbLog()), notifier: RecordingNotifier())
        let job = InstallJob(request: fake.request(), inputs: InstallInputs(runnerID: fake.runner.id, gameName: "Sample Game"))
        center.sheet.show(job)
        center.enqueue(job)
        #expect(await waitFor { job.phase == .failed })
        #expect(job.diagnosis?.causes == [.memory, .path, .damagedFile])
        #expect(job.diagnosis?.explanation == .decompressorMemory)
        #expect(Array(center.sheet.fixes.prefix(3)) == [.lessMemory, .fewerThreads, .verifyFiles])

        center.sheet.retry(.lessMemory)
        #expect(job.inputs.memoryPercent == 50)
        #expect(await waitFor { job.phase == .failed && fake.calledWith().count == 4 })
    }

    @Test("An external-unpacker install: the prefix is prepared first, setup runs guided on short paths, and the helper it spawned is waited on")
    func unpackerFlow() async throws {
        let fake = try FakeInstall("flow-unpacker", behavior: "spawn")
        let verbs = VerbLog()
        let center = InstallCenter(engine: fake.engine(winetricks: verbs), notifier: RecordingNotifier())
        var request = fake.request()
        request.unpacker = ExternalUnpacker(helpers: ["isdone.dll", "unarc.dll"])
        var inputs = InstallInputs(runnerID: fake.runner.id, gameName: "Sample Game", mode: .automatic, language: "en")
        inputs.applyUnpackerProfile(ramBytes: 16 << 30)
        let job = InstallJob(request: request, inputs: inputs)
        center.sheet.show(job)
        let start = Date()
        center.enqueue(job)
        #expect(await waitFor { job.phase == .choosing })

        // The prefix preparation ran before the installer, with the unpacker's verbs.
        #expect(verbs.calls == [["win10", "vcrun2005", "vcrun2008", "vcrun2010"]])
        #expect(job.unpackerPrepInstalled == true)

        // Setup ran guided from drive S: into C:\G\<short>, on the C:\T temp dir — never silent.
        let calls = fake.calledWith()
        let setup = try #require(calls.first { $0.contains("setup.exe") })
        #expect(setup.contains(#"S:\setup.exe /DIR=C:\G\SampleGa"#))
        #expect(setup.hasSuffix(#"TEMP=C:\T"#))
        #expect(!setup.contains("/VERYSILENT"))

        // The spawned helper outlived setup.exe; the engine waited ~2 s for it.
        #expect(Date().timeIntervalSince(start) > 1.5)
        let folder = try #require(job.folder)
        #expect(FileManager.default.fileExists(atPath: folder.prefix.appending(path: "../helper-done").standardizedFileURL.path))

        // The install folder keeps the process journal and a bounded output log.
        #expect(FileManager.default.fileExists(atPath: folder.root.appending(path: "processes.log").path))
        #expect(FileManager.default.fileExists(atPath: folder.prefix.appending(path: "drive_c/T").path, isDirectory: nil))
    }

    @Test("Stop while the checksums verify: the job ends stopped before Wine ever runs")
    func stopDuringVerify() async throws {
        let fake = try FakeInstall("flow-verify-stop", withManifest: true)
        let center = InstallCenter(engine: fake.engine(winetricks: VerbLog()), notifier: RecordingNotifier())
        var inputs = InstallInputs(runnerID: fake.runner.id, gameName: "Sample Game")
        inputs.verifyFirst = true
        let job = InstallJob(request: fake.request(manifest: true), inputs: inputs)
        center.sheet.show(job)
        center.enqueue(job)
        #expect(await waitFor { job.phase == .verifying })
        center.stop(job)
        #expect(await waitFor { job.phase == .stopped })
        #expect(!FileManager.default.fileExists(atPath: fake.calls.path))
    }

    @Test("Retry and requeue on a running job do nothing, so no second run starts")
    func retryWhileRunning() async throws {
        let fake = try FakeInstall("flow-retry-run", behavior: "hang")
        let center = InstallCenter(engine: fake.engine(winetricks: VerbLog()), notifier: RecordingNotifier())
        let job = InstallJob(request: fake.request(), inputs: InstallInputs(runnerID: fake.runner.id, gameName: "Sample Game"))
        center.sheet.show(job)
        center.enqueue(job)
        // wineboot, then the installer itself
        #expect(await waitFor { job.phase == .installing && fake.calledWith().count == 2 })
        let before = fake.calledWith().count
        center.retry(job, with: .lessMemory)
        center.retry(job, fixes: [.lessMemory, .fewerThreads])
        center.requeue(job)
        // Asserting nothing happened needs a beat; the hang gives 30 s of slack.
        try await Task.sleep(for: .milliseconds(300))
        #expect(job.phase == .installing)
        #expect(job.tried.isEmpty)
        #expect(fake.calledWith().count == before)
        center.stop(job)
        #expect(await waitFor { job.phase == .stopped })
    }
}

final class TrashLog: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [URL] = []
    func add(_ url: URL) { lock.withLock { all.append(url) } }
    var urls: [URL] { lock.withLock { all } }
}
