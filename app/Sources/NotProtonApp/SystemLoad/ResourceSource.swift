// One reading of the Mac's load, all without root: libproc for processes, the Mach host for
// the CPU, sysctl for memory, and the IORegistry for the GPU.

import Darwin
import Foundation
import IOKit

struct ProcessReading: Equatable, Sendable {
    var pid: pid_t
    var parent: pid_t
    var uid: uid_t
    var name: String
    var path: String
    // Seconds since 1970, to tell a reused PID from the process it was
    var started: Double
    // nil for a process of another user: libproc only reads usage of our own
    var cpuTime: UInt64?
    var footprint: UInt64?
}

enum MemoryPressure: Int, Codable, Comparable, CaseIterable, Sendable {
    case normal = 1, warning = 2, critical = 4

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

struct MemoryReading: Equatable, Sendable {
    var pressure: MemoryPressure = .normal
    var swapUsed: UInt64 = 0
    var physical: UInt64 = 0
    // As Activity Monitor counts « Memory Used »: app memory, wired and compressed
    var used: UInt64 = 0
}

struct GPUReading: Equatable, Sendable {
    // Device Utilization % of the busiest accelerator; nil when the driver has none
    var device: Double?
    // Cumulated GPU nanoseconds of each process that holds a Metal client
    var perProcess: [pid_t: UInt64] = [:]
    var names: [pid_t: String] = [:]
}

struct ResourceReading: Equatable, Sendable {
    // Monotonic nanoseconds
    var time: UInt64
    var processes: [ProcessReading]
    var cpuBusy: UInt64
    var cpuTotal: UInt64
    var cores: Int
    var gpu: GPUReading
    var memory: MemoryReading
}

protocol ResourceSource: Sendable {
    func read() -> ResourceReading
}

struct LiveResourceSource: ResourceSource {

    func read() -> ResourceReading {
        let (busy, total) = Self.hostTicks()
        return ResourceReading(
            time: clock_gettime_nsec_np(CLOCK_UPTIME_RAW), processes: Self.processes(),
            cpuBusy: busy, cpuTotal: total, cores: ProcessInfo.processInfo.activeProcessorCount,
            gpu: Self.gpu(), memory: Self.memory())
    }

    static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    static func processes() -> [ProcessReading] {
        GameProcesses.allProcesses().compactMap(process)
    }

    static func process(_ pid: pid_t) -> ProcessReading? {
        var info = proc_bsdinfo()
        guard pid >= 0, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0,
              info.pbi_status != UInt32(SZOMB) else { return nil }
        var name = withUnsafeBytes(of: info.pbi_name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        if name.isEmpty {
            name = withUnsafeBytes(of: info.pbi_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        }
        var reading = ProcessReading(
            pid: pid, parent: pid_t(info.pbi_ppid), uid: info.pbi_uid, name: name, path: path(of: pid),
            started: Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000)
        var usage = rusage_info_v4()
        let read = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        if read == 0 {
            let ticks = usage.ri_user_time + usage.ri_system_time
            reading.cpuTime = ticks * UInt64(timebase.numer) / UInt64(timebase.denom)
            reading.footprint = usage.ri_phys_footprint
        }
        return reading
    }

    static func path(of pid: pid_t) -> String {
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return "" }
        return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
    }

    static func hostTicks() -> (busy: UInt64, total: UInt64) {
        var load = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &load) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, 0) }
        let user = UInt64(load.cpu_ticks.0), system = UInt64(load.cpu_ticks.1)
        let idle = UInt64(load.cpu_ticks.2), nice = UInt64(load.cpu_ticks.3)
        return (user + system + nice, user + system + nice + idle)
    }

    static func memory() -> MemoryReading {
        var reading = MemoryReading(physical: ProcessInfo.processInfo.physicalMemory)
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 {
            reading.pressure = MemoryPressure(rawValue: Int(level)) ?? .normal
        }
        var swap = xsw_usage()
        size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 { reading.swapUsed = swap.xsu_used }
        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            let pages = UInt64(vm.internal_page_count) - min(UInt64(vm.internal_page_count), UInt64(vm.purgeable_count))
                + UInt64(vm.wire_count) + UInt64(vm.compressor_page_count)
            reading.used = min(reading.physical, pages * UInt64(getpagesize()))
        }
        return reading
    }

    // Each IOAccelerator's user clients name the process that opened them and, on Apple
    // silicon, the GPU time it used so far.
    static func gpu() -> GPUReading {
        var reading = GPUReading()
        var services: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &services) == KERN_SUCCESS
        else { return reading }
        defer { IOObjectRelease(services) }
        while case let service = IOIteratorNext(services), service != 0 {
            defer { IOObjectRelease(service) }
            if let stats = property(service, "PerformanceStatistics") as? [String: Any],
               let device = (stats["Device Utilization %"] as? NSNumber)?.doubleValue {
                reading.device = max(reading.device ?? 0, device)
            }
            var clients: io_iterator_t = 0
            guard IORegistryEntryGetChildIterator(service, kIOServicePlane, &clients) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(clients) }
            while case let client = IOIteratorNext(clients), client != 0 {
                defer { IOObjectRelease(client) }
                guard let creator = (property(client, "IOUserClientCreator") as? String).flatMap(clientCreator),
                      let usage = property(client, "AppUsage") as? [[String: Any]] else { continue }
                let time = usage.reduce(UInt64(0)) { $0 + ((($1["accumulatedGPUTime"] as? NSNumber)?.uint64Value) ?? 0) }
                reading.perProcess[creator.pid, default: 0] += time
                reading.names[creator.pid] = creator.name
            }
        }
        return reading
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    // "pid 175, WindowServer"
    static func clientCreator(_ text: String) -> (pid: pid_t, name: String)? {
        guard text.hasPrefix("pid ") else { return nil }
        let rest = text.dropFirst(4)
        let digits = rest.prefix { $0.isNumber }
        guard let pid = pid_t(digits) else { return nil }
        var name = rest.dropFirst(digits.count)
        if name.hasPrefix(",") { name = name.dropFirst() }
        return (pid, name.trimmingCharacters(in: .whitespaces))
    }
}
