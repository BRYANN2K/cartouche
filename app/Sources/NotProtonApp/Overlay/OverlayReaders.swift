import AppKit
import CoreMedia
import Foundation
import IOKit
import IOKit.ps
import ScreenCaptureKit

enum MacReaders {
    static func battery() -> Int? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let now = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            return now * 100 / max
        }
        return nil
    }

    // GPU busy % of the whole GPU, as Activity Monitor's GPU History
    static func gpuUtilization() -> Double? {
        let accel = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"))
        guard accel != 0 else { return nil }
        defer { IOObjectRelease(accel) }
        let stats = IORegistryEntryCreateCFProperty(accel, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [String: Any]
        return (stats?["Device Utilization %"] as? NSNumber)?.doubleValue
    }

    // GPU seconds a process used: the sum over its Metal user clients (extfps)
    static func gpuSeconds(of pid: pid_t) -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var total: UInt64 = 0
        var found = false
        let prefix = "pid \(pid),"
        while case let accel = IOIteratorNext(iterator), accel != 0 {
            var children: io_iterator_t = 0
            if IORegistryEntryGetChildIterator(accel, kIOServicePlane, &children) == KERN_SUCCESS {
                while case let child = IOIteratorNext(children), child != 0 {
                    if let creator = IORegistryEntryCreateCFProperty(child, "IOUserClientCreator" as CFString, kCFAllocatorDefault, 0)?
                        .takeRetainedValue() as? String, creator.hasPrefix(prefix) {
                        found = true
                        let usage = IORegistryEntryCreateCFProperty(child, "AppUsage" as CFString, kCFAllocatorDefault, 0)?
                            .takeRetainedValue() as? [[String: Any]] ?? []
                        total += usage.reduce(0) { $0 + (($1["accumulatedGPUTime"] as? NSNumber)?.uint64Value ?? 0) }
                    }
                    IOObjectRelease(child)
                }
                IOObjectRelease(children)
            }
            IOObjectRelease(accel)
        }
        return found ? Double(total) / 1e9 : nil
    }
}

// IOReport's GPU Energy channel, from the private libIOReport, readable without root (extfps).
// nil when the library or the channel is missing: the menu then shows « — ».
final class GPUPower {
    typealias CopyChannels = @convention(c) (CFString, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?
    typealias Subscribe = @convention(c) (UnsafeRawPointer?, CFMutableDictionary, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>, UInt64, CFTypeRef?) -> OpaquePointer?
    typealias Sample = @convention(c) (OpaquePointer, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    typealias Delta = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    typealias Name = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    typealias Integer = @convention(c) (CFDictionary, Int32) -> Int64

    private let sample: Sample, delta: Delta, name: Name, unit: Name, integer: Integer
    private let subscription: OpaquePointer
    private let channels: CFMutableDictionary
    private var last: CFDictionary
    private var lastAt: Date

    init?() {
        guard let lib = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW),
              let c = dlsym(lib, "IOReportCopyChannelsInGroup"), let s = dlsym(lib, "IOReportCreateSubscription"),
              let m = dlsym(lib, "IOReportCreateSamples"), let d = dlsym(lib, "IOReportCreateSamplesDelta"),
              let n = dlsym(lib, "IOReportChannelGetChannelName"), let u = dlsym(lib, "IOReportChannelGetUnitLabel"),
              let i = dlsym(lib, "IOReportSimpleGetIntegerValue") else { return nil }
        let copy = unsafeBitCast(c, to: CopyChannels.self)
        sample = unsafeBitCast(m, to: Sample.self)
        delta = unsafeBitCast(d, to: Delta.self)
        name = unsafeBitCast(n, to: Name.self)
        unit = unsafeBitCast(u, to: Name.self)
        integer = unsafeBitCast(i, to: Integer.self)
        guard let wanted = copy("Energy Model" as CFString, nil, 0, 0, 0)?.takeRetainedValue() else { return nil }
        var subscribed: Unmanaged<CFMutableDictionary>?
        guard let sub = unsafeBitCast(s, to: Subscribe.self)(nil, wanted, &subscribed, 0, nil),
              let chans = subscribed?.takeRetainedValue(),
              let first = sample(sub, chans, nil)?.takeRetainedValue() else { return nil }
        subscription = sub
        channels = chans
        last = first
        lastAt = Date()
    }

    // Watts since the last call
    func gpuWatts() -> Double? {
        guard let now = sample(subscription, channels, nil)?.takeRetainedValue() else { return nil }
        let at = Date()
        defer { last = now; lastAt = at }
        let span = at.timeIntervalSince(lastAt)
        guard span > 0, let diff = delta(last, now, nil)?.takeRetainedValue() as? [String: Any],
              let list = diff["IOReportChannels"] as? [CFDictionary] else { return nil }
        var joules: Double?
        for ch in list {
            guard name(ch)?.takeUnretainedValue() as String? == "GPU Energy" else { continue }
            let label = unit(ch)?.takeUnretainedValue() as String? ?? ""
            let scale = label == "mJ" ? 1e-3 : label == "uJ" ? 1e-6 : label == "nJ" ? 1e-9 : 0
            joules = (joules ?? 0) + Double(integer(ch, 0)) * scale
        }
        return joules.map { $0 / span }
    }
}

// What the overlay asks of a frame counter; the real one is ExternalFrameCounter, tests fake it
protocol ExternalFrameCounting: AnyObject, Sendable {
    var dead: Bool { get }
    func start(pid: pid_t) async -> Bool
    func stop() async
    func metrics(now: Double) -> GameMetrics?
}

// The rate a game window shows, measured from outside the game: a small ScreenCaptureKit stream,
// counting by display time the frames whose pixels changed (extfps). Needs Screen Recording.
final class ExternalFrameCounter: NSObject, SCStreamOutput, SCStreamDelegate, ExternalFrameCounting, @unchecked Sendable {
    private let lock = NSLock()
    private var shown: [Double] = []
    private var lastHash: UInt64 = 0
    private var stream: SCStream?
    private var stopped = false

    static var allowed: Bool { CGPreflightScreenCaptureAccess() }
    static func request() -> Bool { CGRequestScreenCaptureAccess() }

    func start(pid: pid_t) async -> Bool {
        guard Self.allowed,
              let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true),
              let window = content.windows.filter({ $0.owningApplication?.processID == pid && $0.windowLayer < 24 })
                .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else { return false }
        let config = SCStreamConfiguration()
        config.width = 128
        config.height = max(2, Int((128 * window.frame.height / max(window.frame.width, 1)).rounded()))
        config.minimumFrameInterval = .zero
        config.queueDepth = 8
        config.showsCursor = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: window), configuration: config, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "overlay.extfps", qos: .userInteractive))
            try await stream.startCapture()
        } catch {
            return false
        }
        self.stream = stream
        return true
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
    }

    // The stream died: the overlay drops it and starts a fresh one
    var dead: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock()
        stopped = true
        lock.unlock()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first, let raw = info[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let at = info[.displayTime] as? UInt64, let pixels = CMSampleBufferGetImageBuffer(sample) else { return }
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        var hash: UInt64 = 0xcbf29ce484222325
        if let base = CVPixelBufferGetBaseAddress(pixels) {
            let row = CVPixelBufferGetBytesPerRow(pixels), width = CVPixelBufferGetWidth(pixels) * 4
            for y in 0..<CVPixelBufferGetHeight(pixels) {
                let line = base.advanced(by: y * row).assumingMemoryBound(to: UInt64.self)
                for x in 0..<width / 8 { hash = (hash ^ line[x]) &* 0x100000001b3 }
            }
        }
        CVPixelBufferUnlockBaseAddress(pixels, .readOnly)
        lock.lock()
        defer { lock.unlock() }
        if hash != lastHash { record(Self.seconds(at)) }
        lastHash = hash
    }

    // Tests feed display times directly
    func record(_ seconds: Double) {
        shown.append(seconds)
        if shown.count > 1200 { shown.removeFirst(shown.count - 1200) }
    }

    func recordLocked(_ seconds: Double) {
        lock.lock()
        defer { lock.unlock() }
        record(seconds)
    }

    // The last second's frames, the mean interval, the slowest 1 % as a rate (≈), the last 120 intervals
    func metrics(now: Double) -> GameMetrics? {
        lock.lock()
        let times = shown
        lock.unlock()
        guard times.count > 2 else { return nil }
        let second = times.filter { $0 > now - 1 }.count
        let recent = Array(times.suffix(601))
        let intervals = zip(recent.dropFirst(), recent).map { ($0 - $1) * 1000 }
        let last = Array(intervals.suffix(60))
        let slow = intervals.sorted(by: >).prefix(max(1, intervals.count / 100))
        return GameMetrics(presentedFPS: Double(second), realFPS: nil,
                           low1FPS: slow.isEmpty ? 0 : 1000 * Double(slow.count) / slow.reduce(0, +),
                           frameMs: last.isEmpty ? 0 : last.reduce(0, +) / Double(last.count), latencyMs: nil,
                           thermal: ProcessInfo.processInfo.thermalState.rawValue, external: true,
                           frameTimes: Array(intervals.suffix(120)))
    }

    static func seconds(_ hostTime: UInt64) -> Double {
        var t = mach_timebase_info_data_t()
        mach_timebase_info(&t)
        return Double(hostTime) * Double(t.numer) / Double(t.denom) / 1e9
    }

    static func now() -> Double { seconds(mach_absolute_time()) }
}

