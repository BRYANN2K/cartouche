import Darwin
import Foundation
import Testing

@testable import NotProtonApp

// No test here signals a real process: the signaller and the app actions are recorders.
private let second: UInt64 = 1_000_000_000

private func process(_ pid: pid_t, _ name: String, parent: pid_t = 1, path: String? = nil, cpu: UInt64? = 0,
                     memory: UInt64? = 100, uid: uid_t = getuid(), started: Double = 1000) -> ProcessReading {
    ProcessReading(pid: pid, parent: parent, uid: uid, name: name, path: path ?? "/Applications/\(name).app/Contents/MacOS/\(name)",
                   started: started, cpuTime: cpu, footprint: memory)
}

private func reading(at time: UInt64, _ processes: [ProcessReading], busy: UInt64 = 0, total: UInt64 = 0,
                     gpu: [pid_t: UInt64] = [:], gpuNames: [pid_t: String] = [:], device: Double? = nil,
                     pressure: MemoryPressure = .normal) -> ResourceReading {
    ResourceReading(time: time, processes: processes, cpuBusy: busy, cpuTotal: total, cores: 4,
                    gpu: GPUReading(device: device, perProcess: gpu, names: gpuNames),
                    memory: MemoryReading(pressure: pressure, swapUsed: 0, physical: 16 << 30))
}

private func app(_ name: String, id: String? = nil) -> RunningAppInfo {
    RunningAppInfo(name: name, bundleID: id ?? "com.example.\(name.lowercased())", bundlePath: "/Applications/\(name).app")
}

final class ScriptedSource: ResourceSource, @unchecked Sendable {
    private let lock = NSLock()
    private var readings: [ResourceReading]

    init(_ readings: [ResourceReading]) { self.readings = readings }

    func read() -> ResourceReading {
        lock.lock()
        defer { lock.unlock() }
        return readings.count > 1 ? readings.removeFirst() : readings[0]
    }
}

final class RecordingSignaller: ProcessSignalling, @unchecked Sendable {
    private let lock = NSLock()
    private var _sent: [(Int32, pid_t)] = []
    var starts: [pid_t: Double]

    init(starts: [pid_t: Double]) { self.starts = starts }

    var sent: [(Int32, pid_t)] { lock.withLock { _sent } }

    func send(_ signal: Int32, to pid: pid_t) -> Bool {
        lock.withLock { _sent.append((signal, pid)) }
        return true
    }

    func started(_ pid: pid_t) -> Double? { lock.withLock { starts[pid] } }
}

@MainActor
final class RecordingGuard: CrashGuard {
    var armed: [URL] = []
    func arm(list: URL) { armed.append(list) }
}

@MainActor
final class RecordingActions: ProcessActions {
    var quits: [pid_t] = []
    var forced: [pid_t] = []
    func quit(_ row: ResourceUsage) { quits.append(row.pid) }
    func forceQuit(_ row: ResourceUsage) { forced.append(row.pid) }
}

@Suite("Resource sampling")
struct ResourceSamplingTests {

    @Test("The first reading has nothing to compare with; the second gives CPU, memory and GPU per row")
    func cpuMemoryGPU() throws {
        var sampler = ResourceSampler()
        let apps: [pid_t: RunningAppInfo] = [100: app("Browser")]
        let helper = "/Applications/Browser.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper"
        let first = reading(at: 0, [process(100, "Browser", cpu: 0, memory: 300), process(101, "Helper", parent: 100, path: helper, cpu: 0, memory: 200)],
                            busy: 0, total: 0, gpu: [100: 0])
        #expect(sampler.sample(first, apps: apps) == nil)
        let next = reading(at: 2 * second,
                           [process(100, "Browser", cpu: second, memory: 300), process(101, "Helper", parent: 100, path: helper, cpu: second, memory: 200)],
                           busy: 50, total: 200, gpu: [100: second / 2], device: 30)
        let compared = sampler.sample(next, apps: apps)
        let sample = try #require(compared)
        #expect(sample.rows.count == 1)
        let row = try #require(sample.rows.first)
        #expect(row.name == "Browser")
        #expect(row.pids == [100, 101])
        #expect(row.cpu == 100)
        #expect(row.memory == 500)
        #expect(row.gpu == 25)
        #expect(sample.cpuLoad == 25)
        #expect(sample.gpuDevice == 30)
        #expect(sample.gpuPerProcess)
    }

    @Test("A shell a terminal started is its own row, not the terminal's")
    func childOutsideBundleStandsAlone() throws {
        let apps: [pid_t: RunningAppInfo] = [200: app("Terminal")]
        let old = reading(at: 0, [process(200, "Terminal"), process(201, "yes", parent: 200, path: "/usr/bin/yes")])
        let new = reading(at: second, [process(200, "Terminal"), process(201, "yes", parent: 200, path: "/usr/bin/yes", cpu: second)])
        let sample = ResourceSampler.compare(old, new, apps: apps)
        #expect(Set(sample.rows.map(\.name)) == ["Terminal", "yes"])
        #expect(sample.rows.first { $0.name == "yes" }?.cpu == 100)
    }

    @Test("A reused PID reads no CPU, and an unreadable process of another user is left out")
    func reusedAndHidden() {
        let old = reading(at: 0, [process(300, "Old", cpu: 5 * second, started: 10), process(301, "root", cpu: nil, memory: nil, uid: 0)])
        let new = reading(at: second, [process(300, "New", cpu: second, started: 20), process(301, "root", cpu: nil, memory: nil, uid: 0)])
        let sample = ResourceSampler.compare(old, new, apps: [:])
        #expect(sample.rows.map(\.name) == ["New"])
        #expect(sample.rows.first?.cpu == nil)
    }

    @Test("A CPU counter reset between samples saturates at zero, not a wrapped delta")
    func counterReset() {
        let old = reading(at: 0, [], busy: 900, total: 1000)
        let reset = reading(at: second, [], busy: 50, total: 1100)
        #expect(ResourceSampler.compare(old, reset, apps: [:]).cpuLoad == 0)
    }

    @Test("A process seen only through its GPU client still shows, named by the driver")
    func gpuOnlyRow() {
        let old = reading(at: 0, [], gpu: [175: 0], gpuNames: [175: "WindowServer"])
        let new = reading(at: second, [], gpu: [175: second / 10], gpuNames: [175: "WindowServer"])
        let sample = ResourceSampler.compare(old, new, apps: [:])
        #expect(sample.rows.map(\.name) == ["WindowServer"])
        #expect(sample.rows.first?.gpu == 10)
        #expect(sample.rows.first?.memory == nil)
    }

    @Test("The IORegistry creator string gives the PID and the name")
    func clientCreator() {
        #expect(LiveResourceSource.clientCreator("pid 175, WindowServer")?.pid == 175)
        #expect(LiveResourceSource.clientCreator("pid 175, WindowServer")?.name == "WindowServer")
        #expect(LiveResourceSource.clientCreator("pid 9, Siri AI")?.name == "Siri AI")
        #expect(LiveResourceSource.clientCreator("kernel") == nil)
    }

    @Test("The live source reads this test process without root")
    func liveReadsSelf() throws {
        let me = try #require(LiveResourceSource.process(getpid()))
        #expect(me.cpuTime != nil)
        #expect((me.footprint ?? 0) > 0)
        #expect(me.uid == getuid())
    }
}

@Suite("Protected processes")
struct ProtectedProcessesTests {
    let rules = ProtectedProcesses(me: 50, myUID: 501, gameRoots: ["/Users/me/Library/Application Support/Cartouche/"])

    private func p(_ pid: pid_t, _ name: String, parent: pid_t = 1, path: String? = nil, uid: uid_t = 501) -> ProcessReading {
        process(pid, name, parent: parent, path: path, uid: uid)
    }

    @Test("macOS, WindowServer, kernel_task, Finder, the Dock, Cartouche, Wine and the game are always protected")
    func fixedList() {
        let processes: [pid_t: ProcessReading] = [
            0: p(0, "kernel_task", uid: 0),
            175: p(175, "WindowServer", path: "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer", uid: 88),
            900: p(900, "Finder", path: "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder"),
            901: p(901, "Dock", path: "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock"),
            50: p(50, "Cartouche"),
            60: p(60, "wineserver", parent: 50, path: "/opt/wine/bin/wineserver"),
            61: p(61, "Game.exe", parent: 60, path: "/opt/wine/bin/wine64-preloader"),
            62: p(62, "runner", path: "/Users/me/Library/Application Support/Cartouche/runners/x/bin/wine"),
            70: p(70, "Notes", path: "/System/Applications/Notes.app/Contents/MacOS/Notes"),
            71: p(71, "Spotify"),
        ]
        let map = rules.classify(processes, apps: [:])
        #expect(map[0] == .system)
        #expect(map[175] == .system)
        #expect(map[900] == .system)
        #expect(map[901] == .system)
        #expect(map[50] == .cartouche)
        #expect(map[60] == .game)
        #expect(map[61] == .game)
        #expect(map[62] == .game)
        #expect(map[70] == nil)
        #expect(map[71] == nil)
    }

    @Test("Nothing is protected by default")
    func defaultUserList() {
        #expect(ProtectedProcesses.defaultUserList.isEmpty)
        #expect(ProtectedProcesses().userList.isEmpty)
    }

    @Test("The user's own list protects, with every process the app started")
    func userListProtects() {
        var rules = rules
        rules.userList = ["1Password"]
        let processes: [pid_t: ProcessReading] = [
            80: p(80, "1Password"),
            81: p(81, "zsh", parent: 80, path: "/bin/zsh"),
            82: p(82, "node", parent: 81, path: "/opt/homebrew/bin/node"),
            83: p(83, "1Password Helper", path: "/Applications/1Password.app/Contents/Frameworks/1Password Helper"),
            84: p(84, "Spotify"),
            85: p(85, "helper-host", path: "/Users/me/Library/Application Support/agent/host/1Password Browser Helper.app/Contents/MacOS/helper-host"),
            86: p(86, "worker", parent: 85, path: "/Users/me/.local/bin/worker"),
            87: p(87, "OnePassword"),
        ]
        let map = rules.classify(processes, apps: [80: app("1Password", id: "com.1password.1password")])
        #expect(map[80] == .user)
        #expect(map[82] == .user)
        #expect(map[83] == .user)
        #expect(map[84] == nil)
        #expect(map[85] == .user)
        #expect(map[86] == .user)
        #expect(map[87] == nil)
    }

    @Test("A tool the user ran from a shell is theirs; a daemon launchd started from /usr is not")
    func shellToolsAreTheUsers() {
        let processes: [pid_t: ProcessReading] = [
            90: p(90, "Terminal", path: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"),
            91: p(91, "zsh", parent: 90, path: "/bin/zsh"),
            92: p(92, "yes", parent: 91, path: "/usr/bin/yes"),
            93: p(93, "cfprefsd", path: "/usr/sbin/cfprefsd"),
        ]
        let map = rules.classify(processes, apps: [:], unreadable: [175])
        #expect(map[92] == nil)
        #expect(map[93] == .system)
        #expect(map[175] == .system)
    }

    @Test("The user's list matches a name or a bundle ID, any case")
    func adjustableList() {
        var rules = rules
        rules.userList = ["com.example.spotify"]
        let processes: [pid_t: ProcessReading] = [80: p(80, "Reader"), 84: p(84, "Spotify")]
        let map = rules.classify(processes, apps: [84: app("Spotify")])
        #expect(map[80] == nil)
        #expect(map[84] == .user)
        rules.userList = ["SPOTIFY"]
        #expect(rules.classify(processes, apps: [:])[84] == .user)
    }

    @Test("A row with any protected process is protected, the strongest reason first")
    func rowProtection() {
        let row = ResourceUsage(pid: 1, name: "x", pids: [1, 2, 3])
        #expect(ProtectedProcesses.protection(of: row, in: [2: .user, 3: .game]) == .game)
        #expect(ProtectedProcesses.protection(of: row, in: [:]) == nil)
    }
}

@Suite("Load thresholds")
struct LoadThresholdTests {

    private func sample(cpuLoad: Double, cpu: [pid_t: Double] = [:], gpu: [pid_t: Double] = [:], names: [pid_t: String] = [:],
                        rows: [ResourceUsage] = [], pressure: MemoryPressure = .normal, perProcess: Bool = true,
                        device: Double? = nil) -> ResourceSample {
        let processes = Dictionary(uniqueKeysWithValues: names.map { ($0.key, process($0.key, $0.value)) })
        return ResourceSample(rows: rows, processes: processes, cpuByPID: cpu, gpuByPID: gpu, cpuLoad: cpuLoad, cores: 4,
                              gpuDevice: device, gpuPerProcess: perProcess, memory: MemoryReading(pressure: pressure))
    }

    @Test("The default threshold is 60 %, CPU and GPU")
    func defaults() {
        #expect(LoadThresholds().otherCPU == 60)
        #expect(LoadThresholds().otherGPU == 60)
    }

    @Test("The game's own CPU does not count against the Mac")
    func cpuWithoutGame() {
        // The game uses two cores of four: half the Mac
        let busy = sample(cpuLoad: 70, cpu: [10: 200, 20: 80])
        #expect(LoadCheck.otherCPU(busy, game: [10]) == 20)
        #expect(LoadCheck.reasons(busy, game: [10], thresholds: LoadThresholds()) == [])
        #expect(LoadCheck.reasons(busy, game: [], thresholds: LoadThresholds()) == [.cpu(70)])
    }

    @Test("Memory pressure warns from the chosen level")
    func memory() {
        let warning = sample(cpuLoad: 0, pressure: .warning)
        #expect(LoadCheck.reasons(warning, game: [], thresholds: LoadThresholds()) == [.memory(.warning)])
        var critical = LoadThresholds()
        critical.memory = .critical
        #expect(LoadCheck.reasons(warning, game: [], thresholds: critical) == [])
    }

    @Test("Other apps' GPU leaves out the game and WindowServer, which draws the game")
    func gpu() {
        let busy = sample(cpuLoad: 0, gpu: [10: 50, 175: 30, 30: 65], names: [175: "WindowServer"])
        #expect(LoadCheck.otherGPU(busy, game: [10]) == 65)
        #expect(LoadCheck.reasons(busy, game: [10], thresholds: LoadThresholds()) == [.gpu(65)])
        let total = sample(cpuLoad: 0, perProcess: false, device: 80)
        #expect(LoadCheck.otherGPU(total, game: []) == 80)
        #expect(LoadCheck.otherGPU(total, game: [10]) == nil)
    }

    @Test("Turned off, nothing warns")
    func disabled() {
        var off = LoadThresholds()
        off.enabled = false
        #expect(LoadCheck.reasons(sample(cpuLoad: 100, pressure: .critical), game: [], thresholds: off) == [])
    }

    @Test("The warning names the three heaviest rows the user can act on")
    func topThree() throws {
        let rows = [
            ResourceUsage(pid: 1, name: "A", pids: [1], cpu: 300),
            ResourceUsage(pid: 2, name: "B", pids: [2], cpu: 50),
            ResourceUsage(pid: 3, name: "C", pids: [3], cpu: 90),
            ResourceUsage(pid: 4, name: "D", pids: [4], cpu: 10),
            ResourceUsage(pid: 5, name: "kernel", pids: [5], cpu: 400),
            ResourceUsage(pid: 6, name: "Game", pids: [6], cpu: 500),
        ]
        let busy = sample(cpuLoad: 90, rows: rows)
        let verdict = try #require(LoadCheck.verdict(busy, game: [6], protected: [5], thresholds: LoadThresholds()))
        #expect(verdict.top.map(\.name) == ["A", "C", "B"])
    }

    @Test("Thresholds survive a relaunch")
    func persisted() throws {
        let defaults = try #require(UserDefaults(suiteName: "resources-\(UUID().uuidString)"))
        #expect(LoadThresholds.load(defaults) == LoadThresholds())
        var custom = LoadThresholds()
        custom.otherCPU = 65
        custom.enabled = false
        custom.save(defaults)
        #expect(LoadThresholds.load(defaults) == custom)
    }
}

@Suite("Paused processes")
@MainActor
struct PausedProcessesTests {

    @Test("A pause is on disk before the signal, and arms the crash guard")
    func pauseRecords() throws {
        let dir = try scratchDirectory("paused")
        let signaller = RecordingSignaller(starts: [700: 1, 701: 2])
        let guardian = RecordingGuard()
        let paused = PausedProcesses(file: dir.appending(path: "paused.json"), signaller: signaller, crashGuard: guardian)
        let stopped = paused.pause([PausedProcess(pid: 700, started: 1, name: "a"), PausedProcess(pid: 701, started: 2, name: "b")])
        #expect(stopped == [700, 701])
        #expect(signaller.sent.map(\.0) == [SIGSTOP, SIGSTOP])
        #expect(guardian.armed == [paused.list])
        let list = try String(contentsOf: paused.list, encoding: .utf8)
        #expect(list == "700\n701\n")
        #expect(JSONFile.load([PausedProcess].self, from: paused.file)?.map(\.pid) == [700, 701])
    }

    @Test("A process that is gone or was replaced is never stopped")
    func staleTarget() throws {
        let dir = try scratchDirectory("paused")
        let signaller = RecordingSignaller(starts: [700: 99])
        let paused = PausedProcesses(file: dir.appending(path: "paused.json"), signaller: signaller, crashGuard: nil)
        #expect(paused.pause([PausedProcess(pid: 700, started: 1, name: "a"), PausedProcess(pid: 702, started: 1, name: "gone")]) == [])
        #expect(signaller.sent.isEmpty)
        #expect(paused.entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: paused.file.path))
    }

    @Test("The next launch resumes what a crashed Cartouche left paused, never a reused PID")
    func resumeLeftovers() throws {
        let dir = try scratchDirectory("paused")
        let file = dir.appending(path: "paused.json")
        let first = PausedProcesses(file: file, signaller: RecordingSignaller(starts: [700: 1, 701: 2]), crashGuard: nil)
        first.pause([PausedProcess(pid: 700, started: 1, name: "a"), PausedProcess(pid: 701, started: 2, name: "b")])
        // 701 ended while Cartouche was down and its PID went to another process
        let signaller = RecordingSignaller(starts: [700: 1, 701: 50])
        let next = PausedProcesses(file: file, signaller: signaller, crashGuard: nil)
        #expect(next.resumeLeftovers() == [700])
        #expect(signaller.sent.map(\.0) == [SIGCONT])
        #expect(signaller.sent.map(\.1) == [700])
        #expect(next.entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(!FileManager.default.fileExists(atPath: next.list.path))
    }

    @Test("The crash guard script resumes the listed PIDs once the watched process is gone")
    func guardScript() async throws {
        let dir = try scratchDirectory("paused-guard")
        let list = dir.appending(path: "paused.pids")
        // The PIDs are those of throwaway sleeps started here
        let sleeper = Process()
        sleeper.executableURL = URL(filePath: "/bin/sleep")
        sleeper.arguments = ["30"]
        try sleeper.run()
        defer { kill(sleeper.processIdentifier, SIGKILL) }
        let watched = Process()
        watched.executableURL = URL(filePath: "/bin/sleep")
        watched.arguments = ["0.3"]
        try watched.run()
        kill(sleeper.processIdentifier, SIGSTOP)
        try Data("\(sleeper.processIdentifier)\n".utf8).write(to: list)
        let shell = try ShellCrashGuard.spawn(watching: watched.processIdentifier, list: list)
        try await offMain { shell.waitUntilExit() }
        var info = proc_bsdinfo()
        _ = proc_pidinfo(sleeper.processIdentifier, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        #expect(info.pbi_status != UInt32(SSTOP))
    }
}

@Suite("Resource monitor")
@MainActor
struct ResourceMonitorTests {

    private func bareMonitor(_ defaults: UserDefaults) throws -> ResourceMonitor {
        let dir = try scratchDirectory("prot")
        return ResourceMonitor(source: ScriptedSource([reading(at: 0, []), reading(at: second, [])]),
                               paused: PausedProcesses(file: dir.appending(path: "p.json"),
                                                       signaller: RecordingSignaller(starts: [:]), crashGuard: nil),
                               actions: RecordingActions(), defaults: defaults)
    }

    private func monitor(_ readings: [ResourceReading], apps: [pid_t: RunningAppInfo] = [:],
                         starts: [pid_t: Double] = [:]) throws -> (ResourceMonitor, RecordingSignaller, RecordingActions) {
        let dir = try scratchDirectory("monitor")
        let signaller = RecordingSignaller(starts: starts)
        let actions = RecordingActions()
        let defaults = try #require(UserDefaults(suiteName: "monitor-\(UUID().uuidString)"))
        let monitor = ResourceMonitor(source: ScriptedSource(readings),
                                      paused: PausedProcesses(file: dir.appending(path: "p.json"), signaller: signaller, crashGuard: nil),
                                      actions: actions, defaults: defaults)
        monitor.apps = { apps }
        monitor.sleep = { _ in await Task.yield() }
        return (monitor, signaller, actions)
    }

    @Test("A stored list equal to the beta's resets; a chosen list stays")
    func betaListMigrates() throws {
        // The list 0.2.0-beta1 shipped reads as untouched: it clears
        var defaults = try #require(UserDefaults(suiteName: "prot-\(UUID().uuidString)"))
        defaults.set(ProtectedProcesses.betaUserList, forKey: ResourceMonitor.protectedKey)
        var monitor = try bareMonitor(defaults)
        #expect(monitor.userProtected.isEmpty)
        #expect(defaults.stringArray(forKey: ResourceMonitor.protectedKey) == [])
        // Anything else is the user's own choice: kept as stored
        defaults = try #require(UserDefaults(suiteName: "prot-\(UUID().uuidString)"))
        defaults.set(["1Password", "Reader"], forKey: ResourceMonitor.protectedKey)
        monitor = try bareMonitor(defaults)
        #expect(monitor.userProtected == ["1Password", "Reader"])
    }

    @Test("Quit, force quit and pause never reach a protected row")
    func protectedRefused() async throws {
        let processes = [process(80, "1Password"), process(81, "Spotify")]
        let (monitor, signaller, actions) = try monitor([reading(at: 0, processes), reading(at: second, processes)],
                                                        starts: [80: 1000, 81: 1000])
        await monitor.refresh()
        let sample = try #require(await monitor.refresh())
        monitor.userProtected = ["1Password"]
        let passwordApp = try #require(sample.rows.first { $0.name == "1Password" })
        let spotify = try #require(sample.rows.first { $0.name == "Spotify" })
        #expect(monitor.protection(of: passwordApp) == .user)
        for action in [ResourceAction.quit, .forceQuit, .pause] { monitor.perform(action, on: passwordApp) }
        #expect(actions.quits.isEmpty && actions.forced.isEmpty && signaller.sent.isEmpty)
        monitor.perform(.pause, on: spotify)
        #expect(monitor.isPaused(spotify))
        monitor.perform(.quit, on: spotify)
        #expect(actions.quits == [81])
        // A paused app is resumed first, or it could not answer the quit
        #expect(signaller.sent.map(\.0) == [SIGSTOP, SIGCONT])
    }

    @Test("Force quit forgets the paused entry only once the process is really gone")
    func forceQuitKeepsSurvivors() async throws {
        let procs = [process(81, "Spotify", started: 1000)]
        let (monitor, signaller, actions) = try monitor([reading(at: 0, procs), reading(at: second, procs)], starts: [81: 1000])
        await monitor.refresh()
        let sample = try #require(await monitor.refresh())
        let spotify = try #require(sample.rows.first { $0.name == "Spotify" })
        monitor.perform(.pause, on: spotify)
        #expect(monitor.paused.pids == [81])
        // The kill failed: the same process still runs, the entry stays for resume
        monitor.perform(.forceQuit, on: spotify)
        #expect(actions.forced == [81])
        #expect(monitor.paused.pids == [81])
        // Confirmed gone: the entry leaves the journal
        signaller.starts = [:]
        monitor.perform(.forceQuit, on: spotify)
        #expect(monitor.paused.pids.isEmpty)
    }

    @Test("A busy Mac warns at launch, once, and what was paused resumes when the game ends")
    func gameWatch() async throws {
        // Each second Spotify takes three cores and the game one: all four busy, 75 % without the game
        let readings: [ResourceReading] = (0...8).map { (t: Int) -> ResourceReading in
            let n = UInt64(t)
            let spotify = process(81, "Spotify", cpu: 3 * n * second)
            let game = process(82, "Game.exe", path: "/opt/wine/bin/wine64-preloader", cpu: n * second)
            return reading(at: n * second, [spotify, game], busy: 100 * n, total: 100 * n)
        }
        let (monitor, signaller, _) = try monitor(readings, starts: [81: 1000])
        var warnings: [LoadVerdict] = []
        monitor.notify = { warnings.append($0) }
        var polls = [true, true, false]
        monitor.isGameRunning = { polls.isEmpty ? false : polls.removeFirst() }
        await monitor.refresh()
        await monitor.refresh()
        let spotify = try #require(monitor.sample?.rows.first { $0.name == "Spotify" })
        monitor.perform(.pause, on: spotify)
        await monitor.watchGame()
        #expect(warnings.count == 1)
        let named = warnings.first?.top.map { $0.name }
        #expect(named == ["Spotify"])
        #expect(monitor.alert != nil)
        #expect(monitor.pausedPIDs.isEmpty)
        #expect(signaller.sent.map(\.0) == [SIGSTOP, SIGCONT])
    }

    @Test("With the warning off, a launch only watches for the end of the game")
    func warningOff() async throws {
        let busy = [process(81, "Spotify", cpu: 3 * second)]
        let (monitor, _, _) = try monitor([reading(at: 0, [process(81, "Spotify")], total: 100),
                                           reading(at: second, busy, busy: 100, total: 200, pressure: .critical)])
        monitor.thresholds.enabled = false
        var warned = false
        monitor.notify = { _ in warned = true }
        var polls = [true, false]
        monitor.isGameRunning = { polls.isEmpty ? false : polls.removeFirst() }
        await monitor.watchGame()
        #expect(!warned)
        #expect(monitor.alert == nil)
    }

    @Test("Steam is the launcher: never the game, never quittable, its processes one row")
    func steamLauncher() async throws {
        let steam = "/Applications/Steam.app"
        let inner = "/Users/me/Library/Application Support/Steam/Steam.AppBundle/Steam.app"
        let client = process(90, "steam_osx", path: "\(steam)/Contents/MacOS/steam_osx")
        let helper = process(91, "steamwebhelper", parent: 90, path: "\(steam)/Contents/Frameworks/steamwebhelper")
        let stray = process(92, "steamwebhelper", path: "\(inner)/Contents/Frameworks/steamwebhelper")
        let game = process(95, "Game.exe", path: "/opt/wine/bin/wine64-preloader")
        let readings = [reading(at: 0, [client, helper, stray]),
                        reading(at: second, [client, helper, stray]),
                        reading(at: 2 * second, [client, helper, stray, game])]
        let apps: [pid_t: RunningAppInfo] = [90: RunningAppInfo(name: "Steam", bundleID: "com.valvesoftware.steam", bundlePath: steam)]
        let (monitor, _, actions) = try monitor(readings, apps: apps)
        await monitor.refresh()
        let first = try #require(await monitor.refresh())
        // No game running: Steam must not read « Current game » nor count as the game
        let row = try #require(first.rows.first { $0.name == "Steam" })
        #expect(monitor.protection(of: row) == .launcher)
        #expect(monitor.gamePIDs.isEmpty)
        monitor.perform(.quit, on: row)
        #expect(actions.quits.isEmpty)
        // Its stray helpers fold into the same Steam line
        let all = monitor.backgroundRows(all: true)
        #expect(all.filter { $0.usage.name.lowercased().contains("steam") }.count == 1)
        #expect(all.first { $0.usage.name == "Steam" }?.kind == .launcher)
        // A game running: the launcher's load counts as the game's, not the other apps'
        _ = try #require(await monitor.refresh())
        #expect(monitor.gamePIDs.contains(95))
        #expect(monitor.gamePIDs.contains(90))
    }

    @Test("In « Tout », the rows and « Système et autres » add up to the Mac's CPU")
    func allAddsUp() async throws {
        // One core of four busy in the browser; the rest of the 60 % is macOS and unreadable
        let r0 = reading(at: 0, [process(100, "Browser", cpu: 0), process(101, "daemon", cpu: nil, memory: nil, uid: 0)],
                         busy: 0, total: 0)
        let r1 = reading(at: second, [process(100, "Browser", cpu: second),
                                      process(101, "daemon", cpu: nil, memory: nil, uid: 0)],
                         busy: 60, total: 100)
        let (monitor, _, _) = try monitor([r0, r1], apps: [100: app("Browser")])
        await monitor.refresh()
        let sample = try #require(await monitor.refresh())
        #expect(sample.cpuLoad == 60)
        let all = monitor.backgroundRows(all: true)
        #expect(all.last?.kind == .rest)
        #expect(abs(all.map(\.cpu).reduce(0, +) - sample.cpuLoad) < 0.5)
    }

    @Test("The Apps tab lists only what Pause and Quit can act on; Tout lists the rest")
    func appsTabActableOnly() async throws {
        let idle = [
            process(80, "Chrome"),
            process(81, "1Password"),
            process(82, "mds_stores", path: "/System/Library/Frameworks/Metadata.framework/Support/mds_stores"),
            process(83, "wineserver", path: "/opt/wine/bin/wineserver"),
            process(84, "steam_osx", path: "/Applications/Steam.app/Contents/MacOS/steam_osx"),
            process(85, "Spotify"),
        ]
        let busy = idle.map {
            process($0.pid, $0.name, parent: $0.parent, path: $0.path, cpu: second, memory: $0.footprint,
                    uid: $0.uid, started: $0.started)
        }
        let steam = RunningAppInfo(name: "Steam", bundleID: "com.valvesoftware.steam", bundlePath: "/Applications/Steam.app")
        let (monitor, _, _) = try monitor([reading(at: 0, idle), reading(at: second, busy)],
                                         apps: [80: app("Chrome"), 81: app("1Password"), 84: steam, 85: app("Spotify")])
        await monitor.refresh()
        _ = try #require(await monitor.refresh())
        monitor.userProtected = ["1Password"]
        let apps = monitor.backgroundRows(all: false)
        #expect(apps.allSatisfy { $0.kind == .app })
        #expect(Set(apps.map(\.usage.name)) == ["Chrome", "Spotify"])
        #expect(monitor.backgroundRows(all: true).count > apps.count)
    }

    @Test("The launch check only notifies and flags the banner: no window opens by itself")
    func watchNeverOpensWindow() async throws {
        let (monitor, _, _) = try monitor([reading(at: 0, [process(81, "Spotify")], busy: 0, total: 0),
                                          reading(at: second, [process(81, "Spotify", cpu: 3 * second)],
                                                  busy: 180, total: 200)])
        var opens = 0
        monitor.showWindow = { opens += 1 }
        var warned = 0
        monitor.notify = { _ in warned += 1 }
        var polls = [true, false]
        monitor.isGameRunning = { polls.isEmpty ? false : polls.removeFirst() }
        await monitor.watchGame()
        #expect(warned == 1)
        #expect(monitor.alert != nil)
        #expect(opens == 0)
    }

    @Test("The window reads every second while it is open; the game watch stays every five")
    func intervals() {
        #expect(ResourceMonitor.viewInterval == .seconds(1))
        #expect(ResourceMonitor.gameInterval == .seconds(5))
    }
}
