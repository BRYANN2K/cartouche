// Progress is install-folder size vs the estimate; a folder that stops growing while the CPU idles means the installer is stuck.

import Darwin
import Foundation

public struct InstallProgress: Sendable, Equatable {
    public var bytes: Int64 = 0
    public var expected: Int64 = 0
    public var fraction: Double = 0
    public var bytesPerSecond: Double = 0
    public var secondsLeft: Double?
    // Percent of one core, summed over the installer's processes.
    public var cpu: Double = 0
    public var stuck = false

    public init(expected: Int64 = 0) { self.expected = expected }
}

public struct ProgressTracker: Sendable {
    public let expected: Int64
    public let stuckAfter: TimeInterval
    public let stuckCPU: Double

    private var window: [(at: Date, bytes: Int64)] = []
    private var lastBytes: Int64 = -1
    private var lastGrowth: Date
    private var lastSample: Date
    // CPU time since the folder last grew, in core-seconds, to average over the stall.
    private var idleCPU: Double = 0

    public init(expected: Int64, start: Date, stuckAfter: TimeInterval = 300, stuckCPU: Double = 2) {
        self.expected = max(expected, 1)
        self.stuckAfter = stuckAfter
        self.stuckCPU = stuckCPU
        lastGrowth = start
        lastSample = start
    }

    public mutating func record(bytes: Int64, cpu: Double, at now: Date) -> InstallProgress {
        let step = now.timeIntervalSince(lastSample)
        lastSample = now
        if bytes > lastBytes {
            if lastBytes >= 0 { lastGrowth = now; idleCPU = 0 }
            lastBytes = bytes
        } else {
            idleCPU += cpu / 100 * max(step, 0)
        }
        window.append((now, bytes))
        window.removeAll { now.timeIntervalSince($0.at) > 10 }

        var progress = InstallProgress(expected: expected)
        progress.bytes = bytes
        progress.cpu = cpu
        progress.fraction = min(0.99, Double(bytes) / Double(expected))
        if let first = window.first, now.timeIntervalSince(first.at) > 0 {
            progress.bytesPerSecond = max(0, Double(bytes - first.bytes) / now.timeIntervalSince(first.at))
        }
        if progress.bytesPerSecond > 0 {
            progress.secondsLeft = max(0, Double(expected - bytes) / progress.bytesPerSecond)
        }
        let stalled = now.timeIntervalSince(lastGrowth)
        progress.stuck = stalled >= stuckAfter && idleCPU / stalled * 100 < stuckCPU
        return progress
    }
}

public enum FolderSize {
    public static func bytes(_ folder: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey]
        guard let walk = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walk {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            total += Int64(v.totalFileAllocatedSize ?? v.fileSize ?? 0)
        }
        return total
    }
}

// The installer's processes: the one started, its descendants, and any process in the same Wine prefix (wineserver may not be a descendant).
public struct ProcessGroup: Sendable {
    public let root: pid_t
    public let prefix: String?

    public struct Entry: Sendable, Equatable {
        public let pid: pid_t
        public let comm: String
        // Found through the root's parent chain; false when matched by the prefix environment.
        public let descendant: Bool
    }

    public init(root: pid_t, prefix: String?) { self.root = root; self.prefix = prefix }

    // Processes Wine keeps up for the session itself. They do no install work, so the run never
    // waits on them and a stuck one cannot keep a finished install alive.
    static let sessionHelpers: Set<String> = [
        "services.exe", "winedevice.exe", "plugplay.exe", "svchost.exe", "explorer.exe",
        "rpcss.exe", "wineboot.exe", "winemenubuilder", "tabtip.exe", "winedbg.exe",
        "winecfg.exe", "wineconsole.exe", "conhost.exe",
    ]

    public static func isSessionHelper(_ comm: String) -> Bool {
        let name = comm.lowercased()
        return name.hasPrefix("wineserver") || sessionHelpers.contains(name)
    }

    // With `environments` false the KERN_PROCARGS2 scans are skipped: only the root's own
    // descendants are found. Wine spawns every Windows process through wineserver, which is
    // itself inside our tree, so the descendant walk already covers the whole prefix. The
    // WINEPREFIX env match is a best-effort extra for pids we never saw as descendants —
    // recent macOS returns no environment through KERN_PROCARGS2, where it quietly no-ops;
    // reparented children are covered because the monitor keeps tracking seen pids.
    public func entries(environments: Bool = true) -> [Entry] {
        // Root 0/1 would make launchd's whole tree "the installer's processes".
        guard root > 1 else { return [] }
        let all = Self.allPIDs()
        var children: [pid_t: [pid_t]] = [:]
        var comms: [pid_t: String] = [:]
        for pid in all {
            var info = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else { continue }
            children[pid_t(info.pbi_ppid), default: []].append(pid)
            comms[pid] = withUnsafeBytes(of: info.pbi_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        }
        var found: [pid_t: Bool] = [root: true]
        var queue = children[root] ?? []
        while let next = queue.popLast() {
            if found[next] == nil { found[next] = true; queue += children[next] ?? [] }
        }
        if let prefix, environments {
            let marker = "WINEPREFIX=" + prefix
            for pid in all where pid > 1 && found[pid] == nil && Self.environment(of: pid).contains(marker) {
                found[pid] = false
            }
        }
        return found.keys.filter { $0 > 1 && kill($0, 0) == 0 }.sorted()
            .map { Entry(pid: $0, comm: comms[$0] ?? "", descendant: found[$0] ?? false) }
    }

    public func members(environments: Bool = true) -> [pid_t] {
        entries(environments: environments).map(\.pid)
    }

    // pids still doing install work: the root is tracked by its own exit status, the session helpers never count.
    public func live(environments: Bool = true) -> [Entry] {
        entries(environments: environments).filter { $0.pid != root && !Self.isSessionHelper($0.comm) }
    }

    public static func cpuSeconds(_ pids: [pid_t]) -> Double {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        var ticks: UInt64 = 0
        for pid in pids {
            var usage = rusage_info_v2()
            let ok = withUnsafeMutablePointer(to: &usage) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
            }
            if ok == 0 { ticks += usage.ri_user_time + usage.ri_system_time }
        }
        return Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1e9
    }

    static func allPIDs() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let filled = pids.withUnsafeMutableBufferPointer {
            proc_listallpids($0.baseAddress, Int32($0.count * MemoryLayout<pid_t>.size))
        }
        return Array(pids.prefix(Int(max(filled, 0)))).filter { $0 > 0 }
    }

    // KERN_PROCARGS2: argc, the exec path, the argv strings, then the environment.
    static func procArgs(of pid: pid_t) -> (exe: String, argv: [String], env: [String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        let ok = buffer.withUnsafeMutableBytes { sysctl(&mib, 3, $0.baseAddress, &size, nil, 0) }
        guard ok == 0 else { return nil }
        let argc = Int(buffer.withUnsafeBytes { $0.load(as: Int32.self) })
        let strings = buffer[4..<min(size, buffer.count)].split(separator: 0, omittingEmptySubsequences: true)
            .map { String(decoding: $0, as: UTF8.self) }
        guard strings.count > argc else { return nil }
        return (strings[0], Array(strings[1...argc]), Array(strings.dropFirst(1 + argc)))
    }

    static func environment(of pid: pid_t) -> [String] {
        procArgs(of: pid)?.env ?? []
    }

    public static func commandLine(of pid: pid_t) -> String? {
        procArgs(of: pid).map { ([$0.exe] + $0.argv).joined(separator: " ") }
    }
}

public final class InstallRun: @unchecked Sendable {

    public struct Policy: Sendable {
        public var interval: TimeInterval
        public var stuckAfter: TimeInterval
        public var stuckCPU: Double
        public init(interval: TimeInterval = 1, stuckAfter: TimeInterval = 300, stuckCPU: Double = 2) {
            self.interval = interval; self.stuckAfter = stuckAfter; self.stuckCPU = stuckCPU
        }
    }

    public let launch: InstallLaunch
    private let process = Process()
    private let lock = NSLock()
    private var stopped = false
    private var status: Int32?
    private var waiters: [CheckedContinuation<Int32, Never>] = []
    private var outputHandle: FileHandle?
    private var bounded: OutputLog?
    private let drained = DispatchGroup()

    // With `outputLimit` the log file never grows past it: the head stays, the middle is dropped.
    public init(_ launch: InstallLaunch, output: URL? = nil, outputLimit: Int64? = nil) {
        self.launch = launch
        process.executableURL = URL(filePath: launch.executable)
        process.arguments = launch.arguments
        process.environment = launch.environment
        process.currentDirectoryURL = launch.currentDirectory
        process.standardInput = FileHandle.nullDevice
        // waitUntilExit can hang on a concurrency thread, which has no run loop.
        process.terminationHandler = { [weak self] p in self?.finished(p.terminationStatus) }
        if let output, let outputLimit, let log = OutputLog(url: output, limit: outputLimit) {
            bounded = log
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            drained.enter()
            DispatchQueue.global().async {
                while true {
                    let data = pipe.fileHandleForReading.availableData
                    if data.isEmpty { break }
                    log.feed(data)
                }
                log.finish()
                self.drained.leave()
            }
        } else if let output, FileManager.default.createFile(atPath: output.path(percentEncoded: false), contents: nil),
           let handle = try? FileHandle(forWritingTo: output) {
            outputHandle = handle
            process.standardOutput = handle
            process.standardError = handle
        } else {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        }
    }

    public var pid: pid_t { process.processIdentifier }
    public var isRunning: Bool { lock.withLock { status == nil } && process.isRunning }
    public var wasStopped: Bool { lock.withLock { stopped } }
    public var outputSkipped: Int64 { bounded?.skipped ?? 0 }

    public var group: ProcessGroup { ProcessGroup(root: pid, prefix: launch.environment["WINEPREFIX"]) }

    public func start() throws { try process.run() }

    // Returns once the run can truly be called finished: the root has exited and nothing in its
    // group or prefix is still alive. Inno's setup.exe can exit while the inner setup or the
    // unpackers it spawned keep working; a verdict before they are gone reads a half-written result.
    public func monitor(
        folder: URL, expected: Int64, policy: Policy = Policy(), journal: ProcessJournal? = nil,
        onTick: @Sendable () -> Void = {}, onProgress: @Sendable (InstallProgress) -> Void
    ) async -> Int32 {
        var tracker = ProgressTracker(expected: expected, start: Date(), stuckAfter: policy.stuckAfter, stuckCPU: policy.stuckCPU)
        var live: Set<pid_t> = []
        var lastCPU = ProcessGroup.cpuSeconds(group.members())
        var lastTime = Date()
        var tick = 0
        while true {
            try? await Task.sleep(for: .seconds(policy.interval))
            if Task.isCancelled { stop() }
            onTick()
            let now = Date()
            let rootAlive = lock.withLock { status == nil }
            // The per-pid environment scan is the expensive part; every 10 ticks while the root
            // lives, every tick while the group drains after it.
            tick += 1
            let complete = !rootAlive || tick % 10 == 0
            let entries = group.entries(environments: complete)
            let workers = entries.filter { $0.pid != pid && !ProcessGroup.isSessionHelper($0.comm) }
            // Union, never replace: a worker reparented to launchd between scans is still the
            // install's process until it dies — a scan snapshot alone would lose it.
            live.formUnion(complete ? workers.map(\.pid) : workers.filter(\.descendant).map(\.pid))
            live = live.filter { kill($0, 0) == 0 }
            journal?.record(descendants: entries.filter { $0.descendant && !ProcessGroup.isSessionHelper($0.comm) },
                            environment: complete ? entries.filter { !ProcessGroup.isSessionHelper($0.comm) } : nil, at: now)
            let cpuNow = ProcessGroup.cpuSeconds(entries.map(\.pid))
            // A process that exited takes its CPU time with it, so the sum can drop.
            let cpu = max(0, cpuNow - lastCPU) / max(now.timeIntervalSince(lastTime), 0.001) * 100
            lastCPU = cpuNow; lastTime = now
            onProgress(tracker.record(bytes: FolderSize.bytes(folder), cpu: cpu, at: now))
            if !rootAlive && live.isEmpty { break }
        }
        return await exitStatus()
    }

    public func exitStatus() async -> Int32 {
        await withCheckedContinuation { continuation in
            let known: Int32? = lock.withLock {
                if status == nil { waiters.append(continuation) }
                return status
            }
            if let known { continuation.resume(returning: known) }
        }
    }

    private func finished(_ code: Int32) {
        let pending = lock.withLock {
            status = code
            defer { waiters = [] }
            return waiters
        }
        try? outputHandle?.close()
        // The pipe reader flushes the tail of the log after the process dies.
        if bounded != nil { _ = drained.wait(timeout: .now() + 10) }
        for waiter in pending { waiter.resume(returning: code) }
    }

    // Refuses to signal before start or after exit: pid 0 is the caller's own process group, an exited pid may have been reused.
    public func stop() {
        lock.withLock { stopped = true }
        guard pid > 1, lock.withLock({ status == nil }) else { return }
        let members = group.members()
        for pid in members { kill(pid, SIGTERM) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            for pid in members where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        }
    }
}
