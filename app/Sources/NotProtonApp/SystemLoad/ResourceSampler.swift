import Darwin
import Foundation

struct RunningAppInfo: Equatable, Sendable {
    var name: String
    var bundleID: String?
    var bundlePath: String?
}

// One row of the Resources view: an app with every process it started, or a lone process.
struct ResourceUsage: Identifiable, Equatable, Sendable {
    var id: pid_t { pid }
    var pid: pid_t
    var name: String
    var bundleID: String?
    var bundlePath: String?
    var pids: [pid_t]
    // Percent of one core, as Activity Monitor counts it; nil when macOS hides it from us
    var cpu: Double?
    var memory: UInt64?
    var gpu: Double?
    var isApp: Bool { bundlePath != nil }
}

struct ResourceSample: Equatable, Sendable {
    var rows: [ResourceUsage]
    var processes: [pid_t: ProcessReading]
    var cpuByPID: [pid_t: Double]
    var gpuByPID: [pid_t: Double]
    var gpuNames: [pid_t: String] = [:]
    // Whole-Mac CPU busy, 0 to 100
    var cpuLoad: Double
    var cores: Int
    var gpuDevice: Double?
    // False when the driver keeps no per-process GPU time, as on Intel Macs
    var gpuPerProcess: Bool
    var memory: MemoryReading
}

struct ResourceSampler: Sendable {
    private(set) var last: ResourceReading?

    // nil on the first reading: usage is the difference between two
    mutating func sample(_ reading: ResourceReading, apps: [pid_t: RunningAppInfo]) -> ResourceSample? {
        defer { last = reading }
        guard let last, reading.time > last.time else { return nil }
        return Self.compare(last, reading, apps: apps)
    }

    static func compare(_ old: ResourceReading, _ new: ResourceReading, apps: [pid_t: RunningAppInfo]) -> ResourceSample {
        let elapsed = Double(new.time - old.time)
        let before = Dictionary(old.processes.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var cpu: [pid_t: Double] = [:]
        for process in new.processes {
            guard let now = process.cpuTime, let prior = before[process.pid],
                  prior.started == process.started, let then = prior.cpuTime, now >= then else { continue }
            cpu[process.pid] = Double(now - then) / elapsed * 100
        }
        var gpu: [pid_t: Double] = [:]
        for (pid, now) in new.gpu.perProcess {
            let then = old.gpu.perProcess[pid] ?? now
            gpu[pid] = now >= then ? min(100, Double(now - then) / elapsed * 100) : 0
        }
        let busy = new.cpuBusy > old.cpuBusy ? new.cpuBusy - old.cpuBusy : 0
        let total = new.cpuTotal > old.cpuTotal ? new.cpuTotal - old.cpuTotal : 0
        let load = total > 0 ? min(100, Double(busy) / Double(total) * 100) : 0
        let processes = Dictionary(new.processes.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        return ResourceSample(
            rows: rows(processes: processes, cpu: cpu, gpu: gpu, gpuNames: new.gpu.names, apps: apps),
            processes: processes, cpuByPID: cpu, gpuByPID: gpu, gpuNames: new.gpu.names, cpuLoad: load, cores: max(1, new.cores),
            gpuDevice: new.gpu.device, gpuPerProcess: !new.gpu.perProcess.isEmpty, memory: new.memory)
    }

    // A process belongs to the nearest app above it; the rest stand alone. Processes macOS
    // tells nothing about (other users, no GPU client) are left out.
    static func rows(processes: [pid_t: ProcessReading], cpu: [pid_t: Double], gpu: [pid_t: Double],
                     gpuNames: [pid_t: String], apps: [pid_t: RunningAppInfo]) -> [ResourceUsage] {
        var grouped: [pid_t: ResourceUsage] = [:]
        let everyone = Set(processes.keys).union(gpu.keys)
        for pid in everyone {
            let process = processes[pid]
            guard process?.footprint != nil || gpu[pid] != nil else { continue }
            let owner = owningApp(of: pid, processes: processes, apps: apps) ?? pid
            var row = grouped[owner] ?? {
                let app = apps[owner]
                return ResourceUsage(
                    pid: owner, name: app?.name ?? processes[owner]?.name ?? gpuNames[owner] ?? String(owner),
                    bundleID: app?.bundleID, bundlePath: app?.bundlePath, pids: [])
            }()
            row.pids.append(pid)
            if let value = cpu[pid] { row.cpu = (row.cpu ?? 0) + value }
            if let value = process?.footprint { row.memory = (row.memory ?? 0) + value }
            if let value = gpu[pid] { row.gpu = min(100, (row.gpu ?? 0) + value) }
            grouped[owner] = row
        }
        return grouped.values.map { row in
            var row = row
            row.pids.sort()
            return row
        }.sorted { ($0.cpu ?? 0, $1.pid) > ($1.cpu ?? 0, $0.pid) }
    }

    // Only helpers from inside the app's bundle count: a shell a terminal started, or a game
    // Cartouche started, is its own row.
    static func owningApp(of pid: pid_t, processes: [pid_t: ProcessReading], apps: [pid_t: RunningAppInfo]) -> pid_t? {
        if apps[pid] != nil { return pid }
        let path = processes[pid]?.path ?? ""
        var current = pid
        for _ in 0..<32 {
            if let app = apps[current] {
                guard let bundle = app.bundlePath, path.hasPrefix(bundle.hasSuffix("/") ? bundle : bundle + "/") else { return nil }
                return current
            }
            guard let parent = processes[current]?.parent, parent > 1, parent != current else { return nil }
            current = parent
        }
        return nil
    }
}
