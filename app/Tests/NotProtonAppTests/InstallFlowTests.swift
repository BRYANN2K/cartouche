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
    init(_ label: String, behavior: String = "ok") throws {
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
        for name in ["setup.exe", "data-01.bin", "data-02.bin"] {
            try Data(trapScript.utf8).write(to: source.appending(path: name))
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.appending(path: name).path)
        }
        try Data("; checksums\n".utf8).write(to: source.appending(path: "MD5/checksums.md5"))

        let root = SupportPaths.clonedRoot(forBuild: runner.id, runners: runners)
        let server = root.appending(path: "bin/wineserver")
        try fm.createDirectory(at: server.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: server)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: server.path)

        let wine = root.appending(path: "lib/wine/x86_64-unix/wine")
        let script = """
        #!/bin/sh
        echo "$(uname -m) $*" >> '\(calls.path)'
        if [ "$1" = wineboot ]; then mkdir -p "$WINEPREFIX/drive_c/users/crossover/Temp"; exit 0; fi
        dir=""
        for a in "$@"; do case "$a" in /DIR=*) dir="${a#/DIR=}";; esac; done
        game="$WINEPREFIX/drive_c/$(echo "${dir#C:\\\\}" | tr '\\\\' '/')"
        case '\(behavior)' in
        hang) mkdir -p "$game"; sleep 30; exit 0;;
        unarc)
          printf 'Starting the installation process.\\nAn error occurred while unpacking: Unarc.dll returned an error code: -11\\nERROR: archive data corrupted (decompression fails)\\n' > "$WINEPREFIX/drive_c/installer.log"
          exit 0;;
        esac
        mkdir -p "$game/_Redist"
        for i in 1 2 3 4; do head -c 300000 /dev/zero >> "$game/game.exe"; sleep 0.2; done
        head -c 2000 /dev/zero > "$game/unins000.exe"
        head -c 1000 /dev/zero > "$game/_Redist/dxwebsetup.exe"
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
        engine.winetricks = { verbs, _, _, _ in winetricks.add(verbs) }
        return engine
    }

    func request() -> InstallRequest {
        let files = ["setup.exe", "data-01.bin", "data-02.bin", "MD5/checksums.md5"].map { source.appending(path: $0) }
        return InstallRequest(setup: source.appending(path: "setup.exe"), source: source, name: "Sample Game", appID: 632_470,
                              gogID: nil, expectedBytes: 1_200_000, installerBytes: 10_000, installerFiles: files, manifest: nil)
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
        #expect(calls.first == "x86_64 wineboot --init")
        #expect(calls.dropFirst().first == "x86_64 \(fake.source.appending(path: "setup.exe").path) /DIR=C:\\Games\\Sample Game /NORESTART /LOG=C:\\installer.log /LANG=en")
        #expect(calls.count == 2)
        #expect(!FileManager.default.fileExists(atPath: fake.trap.path))

        // The redistributable was not run; its winetricks verb was installed instead.
        #expect(verbs.calls == [["d3dx9"]])
        #expect(job.redistributablesInstalled == true)
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
        let outcome = try center.engine.finish(job, exe: URL(filePath: exe), showInSteam: true, steam: steam)
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
        #expect(Array(center.sheet.fixes.prefix(3)) == [.verifyFiles, .fewerThreads, .lessMemory])

        center.sheet.retry(.lessMemory)
        #expect(job.inputs.memoryPercent == 50)
        #expect(await waitFor { job.phase == .failed && fake.calledWith().count == 4 })
    }
}

final class TrashLog: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [URL] = []
    func add(_ url: URL) { lock.withLock { all.append(url) } }
    var urls: [URL] { lock.withLock { all } }
}
