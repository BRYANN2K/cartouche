import Foundation
import Testing
@testable import InstallerKit

private let t0 = Date(timeIntervalSince1970: 1_000_000)

final class Box<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    func append(_ item: T) { lock.withLock { items.append(item) } }
    var all: [T] { lock.withLock { items } }
}

@Suite("Install progress")
struct ProgressTrackerTests {

    @Test("Progress follows the folder size, with speed and time left")
    func rises() {
        var t = ProgressTracker(expected: 1000, start: t0)
        _ = t.record(bytes: 0, cpu: 90, at: t0)
        let a = t.record(bytes: 100, cpu: 90, at: t0 + 1)
        let b = t.record(bytes: 300, cpu: 90, at: t0 + 2)
        #expect(a.fraction == 0.1)
        #expect(b.fraction == 0.3)
        #expect(b.bytesPerSecond == 150)
        #expect(b.secondsLeft == 700.0 / 150)
        #expect(!b.stuck)
    }

    @Test("The bar stops short of full until the installer exits")
    func capped() {
        var t = ProgressTracker(expected: 100, start: t0)
        #expect(t.record(bytes: 500, cpu: 50, at: t0 + 1).fraction == 0.99)
    }

    @Test("No growth for 5 minutes with the CPU under 2% is stuck")
    func stuck() {
        var t = ProgressTracker(expected: 1000, start: t0)
        _ = t.record(bytes: 10, cpu: 80, at: t0)
        _ = t.record(bytes: 20, cpu: 80, at: t0 + 1)
        var last = InstallProgress()
        for s in stride(from: 2.0, through: 301, by: 1) {
            last = t.record(bytes: 20, cpu: 0.5, at: t0 + s)
            if s < 301 { #expect(!last.stuck) }
        }
        #expect(last.stuck)
        #expect(!t.record(bytes: 30, cpu: 0.5, at: t0 + 302).stuck)
    }

    @Test("No growth while the CPU is busy is not stuck: decompression can take long between files")
    func busyIsNotStuck() {
        var t = ProgressTracker(expected: 1000, start: t0)
        _ = t.record(bytes: 10, cpu: 80, at: t0)
        _ = t.record(bytes: 20, cpu: 80, at: t0 + 1)
        var last = InstallProgress()
        for s in stride(from: 2.0, through: 400, by: 1) { last = t.record(bytes: 20, cpu: 95, at: t0 + s) }
        #expect(!last.stuck)
    }

    @Test("The folder size counts files in subfolders")
    func folderSize() throws {
        let dir = try tempFolder(["a/b/c.bin": String(repeating: "x", count: 5000), "d.bin": "y"])
        #expect(FolderSize.bytes(dir) >= 5001)
    }
}

@Suite("Install runner", .serialized)
struct InstallRunnerTests {

    @Test("A fake installer that writes files and exits 0: progress rises and the status is 0")
    func completes() async throws {
        let folder = try tempFolder([:]).appending(path: "Games/Sample")
        let script = try tempFolder([:]).appending(path: "setup.sh")
        try executable(script, """
        #!/bin/sh
        mkdir -p '\(folder.path)'
        for i in 1 2 3 4 5 6; do
          head -c 200000 /dev/zero > '\(folder.path)'/part$i.dat
          sleep 0.3
        done
        exit 0
        """)
        let run = InstallRun(InstallLaunch(executable: "/bin/sh", arguments: [script.path], environment: [:]))
        try run.start()
        let seen = Box<InstallProgress>()
        let status = await run.monitor(folder: folder, expected: 1_200_000, policy: .init(interval: 0.2)) { seen.append($0) }
        #expect(status == 0)
        let fractions = seen.all.map(\.fraction)
        #expect(fractions.count >= 4)
        #expect(fractions == fractions.sorted())
        #expect((fractions.last ?? 0) > 0.5)
    }

    @Test("A fake installer that stops writing and idles is reported stuck, and Stop ends it")
    func stuckThenStopped() async throws {
        let folder = try tempFolder(["seed.dat": "x"])
        let script = try tempFolder([:]).appending(path: "setup.sh")
        try executable(script, "#!/bin/sh\nsleep 60\n")
        let run = InstallRun(InstallLaunch(executable: "/bin/sh", arguments: [script.path], environment: [:]))
        try run.start()
        let seen = Box<InstallProgress>()
        let start = Date()
        let status = await run.monitor(folder: folder, expected: 1000, policy: .init(interval: 0.2, stuckAfter: 1)) { p in
            seen.append(p)
            if p.stuck { run.stop() }
        }
        #expect(seen.all.contains { $0.stuck })
        #expect(run.wasStopped)
        #expect(status != 0)
        #expect(Date().timeIntervalSince(start) < 30)
    }

    @Test("CPU is sampled over the installer's processes, children included")
    func cpuOfChildren() async throws {
        let folder = try tempFolder([:])
        let script = try tempFolder([:]).appending(path: "setup.sh")
        // The busy loop runs in a child shell, as the decompressors run as child processes.
        try executable(script, "#!/bin/sh\n/bin/sh -c 'i=0; while [ $i -lt 1500000 ]; do i=$((i+1)); done'\n")
        let run = InstallRun(InstallLaunch(executable: "/bin/sh", arguments: [script.path], environment: [:]))
        try run.start()
        let seen = Box<InstallProgress>()
        _ = await run.monitor(folder: folder, expected: 1000, policy: .init(interval: 0.5)) { seen.append($0) }
        let peak = seen.all.map(\.cpu).max() ?? 0
        #expect(peak > 30)
        #expect(peak < 150)
    }

    @Test("The run is not finished while a process of the prefix is alive: setup exits first, a reparented helper keeps working")
    func drainsAfterRootExits() async throws {
        let prefix = try tempFolder([:]).appending(path: "pfx")
        let folder = prefix.appending(path: "drive_c/G/X")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let marker = prefix.appending(path: "helper-done")
        let journalFile = prefix.appending(path: "processes.log")
        // setup.sh spawns a helper in the background, lingers 0.6 s, then exits. The monitor
        // sees the helper as a descendant first; once the root dies the helper is reparented
        // to launchd and only the monitor's seen-pid tracking still ties it to this install.
        let script = try tempFolder([:]).appending(path: "setup.sh")
        try executable(script, """
        #!/bin/sh
        /bin/sh -c 'sleep 2; touch "\(marker.path)"' &
        sleep 0.6
        exit 0
        """)
        let launch = InstallLaunch(executable: "/bin/sh", arguments: [script.path],
                                   environment: ["WINEPREFIX": prefix.path(percentEncoded: false)])
        let run = InstallRun(launch)
        try run.start()
        let journal = ProcessJournal(file: journalFile)
        let start = Date()
        let status = await run.monitor(folder: folder, expected: 1, policy: .init(interval: 0.2), journal: journal) { _ in }
        journal?.finish(root: run.pid, status: status)
        journal?.close()
        #expect(status == 0)
        // Without the drain the verdict would land after one tick (~0.2 s); the helper sleeps 2.
        #expect(Date().timeIntervalSince(start) > 1.5)
        #expect(FileManager.default.fileExists(atPath: marker.path))
        let journalText = try String(contentsOf: journalFile, encoding: .utf8)
        #expect(journalText.contains("+ \(run.pid) "))
        #expect(journalText.contains("= \(run.pid) "))
        #expect(journalText.contains("exited, status 0"))
    }

    @Test("Session helpers like wineserver or explorer.exe are never waited on")
    func sessionHelpers() {
        #expect(ProcessGroup.isSessionHelper("wineserver"))
        #expect(ProcessGroup.isSessionHelper("wineserver64"))
        #expect(ProcessGroup.isSessionHelper("services.exe"))
        #expect(ProcessGroup.isSessionHelper("explorer.exe"))
        #expect(!ProcessGroup.isSessionHelper("setup.tmp"))
        #expect(!ProcessGroup.isSessionHelper("unarc.exe"))
        #expect(!ProcessGroup.isSessionHelper("precomp.exe"))
    }

    @Test("Processes sharing the Wine prefix count as the installer's")
    func prefixMembers() async throws {
        let marker = "/tmp/cartouche-test-prefix-\(UUID().uuidString)"
        let other = Process()
        other.executableURL = URL(filePath: "/bin/sleep")
        other.arguments = ["5"]
        other.environment = ["WINEPREFIX": marker]
        try other.run()
        defer { other.terminate() }
        let group = ProcessGroup(root: getpid(), prefix: marker)
        #expect(group.members().contains(other.processIdentifier))
        let unrelated = Process()
        unrelated.executableURL = URL(filePath: "/bin/sleep")
        unrelated.arguments = ["5"]
        try unrelated.run()
        defer { unrelated.terminate() }
        #expect(!ProcessGroup(root: unrelated.processIdentifier, prefix: marker + "-not").members().contains(other.processIdentifier))
    }
}
