// Runs the installer and watches it: progress is the size of the install
// folder against the estimate, CPU is summed over the installer's processes, and
// a folder that stops growing while the CPU idles means the installer is stuck.

import Darwin
import Foundation

public struct InstallProgress: Sendable, Equatable {
    public var bytes: Int64 = 0
    public var expected: Int64 = 0
    // Below 1 until the installer exits: the estimate is only an estimate.
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

// The installer's processes: the one we started, its descendants, and any
// process running in the same Wine prefix (wineserver and the decompressors
// may not be descendants).
public struct ProcessGroup: Sendable {
    public let root: pid_t
    public let prefix: String?

    public init(root: pid_t, prefix: String?) { self.root = root; self.prefix = prefix }

    public func members() -> [pid_t] {
        let all = Self.allPIDs()
        var parent: [pid_t: pid_t] = [:]
        for pid in all {
            var info = proc_bsdinfo()
            if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 {
                parent[pid] = pid_t(info.pbi_ppid)
            }
        }
        var found: Set<pid_t> = [root]
        var changed = true
        while changed {
            changed = false
            for (pid, ppid) in parent where found.contains(ppid) && !found.contains(pid) {
                found.insert(pid); changed = true
            }
        }
        if let prefix {
            let marker = "WINEPREFIX=" + prefix
            for pid in all where !found.contains(pid) && Self.environment(of: pid).contains(marker) {
                found.insert(pid)
            }
        }
        return found.filter { kill($0, 0) == 0 }.sorted()
    }

    // Total CPU time of the processes, in seconds.
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

    // KERN_PROCARGS2: argc, the exec path, the arguments, then the environment.
    static func environment(of pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }
        let argc = Int(buffer.withUnsafeBytes { $0.load(as: Int32.self) })
        let strings = buffer[4..<size].split(separator: 0, omittingEmptySubsequences: true)
            .map { String(decoding: $0, as: UTF8.self) }
        // First the exec path, then argc arguments; the rest is the environment.
        return Array(strings.dropFirst(1 + argc))
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

    public init(_ launch: InstallLaunch, output: URL? = nil) {
        self.launch = launch
        process.executableURL = URL(filePath: launch.executable)
        process.arguments = launch.arguments
        process.environment = launch.environment
        process.currentDirectoryURL = launch.currentDirectory
        process.standardInput = FileHandle.nullDevice
        // waitUntilExit can hang on a concurrency thread, which has no run loop.
        process.terminationHandler = { [weak self] p in self?.finished(p.terminationStatus) }
        if let output, FileManager.default.createFile(atPath: output.path(percentEncoded: false), contents: nil),
           let handle = try? FileHandle(forWritingTo: output) {
            process.standardOutput = handle
            process.standardError = handle
        } else {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        }
    }

    public var pid: pid_t { process.processIdentifier }
    public var wasStopped: Bool { lock.withLock { stopped } }

    public var group: ProcessGroup { ProcessGroup(root: pid, prefix: launch.environment["WINEPREFIX"]) }

    public func start() throws { try process.run() }

    // Samples every interval until the process exits, then returns its status.
    public func monitor(
        folder: URL, expected: Int64, policy: Policy = Policy(),
        onTick: @Sendable () -> Void = {}, onProgress: @Sendable (InstallProgress) -> Void
    ) async -> Int32 {
        var tracker = ProgressTracker(expected: expected, start: Date(), stuckAfter: policy.stuckAfter, stuckCPU: policy.stuckCPU)
        var lastCPU = ProcessGroup.cpuSeconds(group.members())
        var lastTime = Date()
        while lock.withLock({ status == nil }) {
            try? await Task.sleep(for: .seconds(policy.interval))
            if Task.isCancelled { stop() }
            onTick()
            let now = Date()
            let cpuNow = ProcessGroup.cpuSeconds(group.members())
            // A process that exited takes its CPU time with it, so the sum can drop.
            let cpu = max(0, cpuNow - lastCPU) / max(now.timeIntervalSince(lastTime), 0.001) * 100
            lastCPU = cpuNow; lastTime = now
            onProgress(tracker.record(bytes: FolderSize.bytes(folder), cpu: cpu, at: now))
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
        for waiter in pending { waiter.resume(returning: code) }
    }

    // SIGTERM to every process of the installer, SIGKILL to what is left after 3 s.
    public func stop() {
        lock.withLock { stopped = true }
        let members = group.members()
        for pid in members { kill(pid, SIGTERM) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            for pid in members where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        }
    }
}
