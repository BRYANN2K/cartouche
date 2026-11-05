// Frame rate of a game window, measured from outside the game: nothing is loaded into the
// game's process and nothing attaches to it, so it suits games with an anti-cheat.
//
//   extfps (--pid <pid> | --window <id> | --title <text>) [--seconds <s>] [--size <px>] [--times <file>] [--count pixels|dirty|all] [--quiet]
//
// Frames: a ScreenCaptureKit stream on the game window, small, counting by display time the
// frames whose pixels changed. That is the rate the player sees: at most the screen's refresh,
// and a frame the game repeats unchanged is not counted.
// Also, sampled once a second: GPU busy % of the whole GPU and GPU time of the game's process
// (IOKit, AGX user clients), CPU and memory of the process (proc_pid_rusage), thermal state, and
// GPU power from IOReport (CPU power needs root).
// One line per second, a summary at the end. --times writes each frame's display time, in
// seconds of host time, as the stand-in game's --times does.

import AppKit
import CoreMedia
import Foundation
import IOKit
import ScreenCaptureKit

struct Options {
	var pid: pid_t = 0
	var window: CGWindowID = 0
	var title: String?
	var seconds = 10.0
	var size = 128
	var times: String?
	var quiet = false
	var count = Frames.Count.pixels
}

func parse() -> Options {
	var o = Options()
	var args = CommandLine.arguments.dropFirst().makeIterator()
	while let a = args.next() {
		switch a {
		case "--pid": o.pid = pid_t(args.next() ?? "") ?? 0
		case "--window": o.window = CGWindowID(args.next() ?? "") ?? 0
		case "--title": o.title = args.next()
		case "--seconds": o.seconds = Double(args.next() ?? "") ?? 10
		case "--size": o.size = Int(args.next() ?? "") ?? 128
		case "--times": o.times = args.next()
		case "--quiet": o.quiet = true
		case "--count": o.count = Frames.Count(rawValue: args.next() ?? "") ?? .pixels
		default:
			FileHandle.standardError.write("extfps: unknown argument \(a)\n".data(using: .utf8)!)
			exit(2)
		}
	}
	if o.pid == 0 && o.window == 0 && o.title == nil {
		FileHandle.standardError.write("usage: extfps (--pid <pid> | --window <id> | --title <text>) [--seconds <s>] [--size <px>] [--times <file>] [--count pixels|dirty|all] [--quiet]\n".data(using: .utf8)!)
		exit(2)
	}
	return o
}

let timebase: Double = {
	var t = mach_timebase_info_data_t()
	mach_timebase_info(&t)
	return Double(t.numer) / Double(t.denom) / 1e9
}()

func hostSeconds() -> Double { Double(mach_absolute_time()) * timebase }

// Mean of the slowest 1 % of intervals, as a rate
func lowOnePercent(_ intervals: [Double]) -> Double {
	guard !intervals.isEmpty else { return 0 }
	let slow = intervals.sorted(by: >).prefix(max(1, intervals.count / 100))
	return Double(slow.count) / slow.reduce(0, +)
}

// WindowServer hands a complete frame on every refresh the window is composited, changed or
// not: a frame counts when its pixels differ from the one before (FNV-1a over the small image).
// --count dirty counts frames with dirty rects instead, all counts every complete frame.
final class Frames: NSObject, SCStreamOutput, SCStreamDelegate {
	enum Count: String { case pixels, dirty, all }
	struct Frame { let at: Double; let dirty: Bool; let changed: Bool }
	private let lock = NSLock()
	private var all: [Frame] = []
	private var lastHash: UInt64 = 0
	private(set) var other = 0

	func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
		guard type == .screen,
		      let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
		      let info = attachments.first,
		      let raw = info[.status] as? Int, let status = SCFrameStatus(rawValue: raw) else { return }
		lock.lock()
		defer { lock.unlock() }
		guard status == .complete, let shown = info[.displayTime] as? UInt64,
		      let pixels = CMSampleBufferGetImageBuffer(sample) else {
			other += 1
			return
		}
		let dirty = !((info[.dirtyRects] as? [Any])?.isEmpty ?? true)
		CVPixelBufferLockBaseAddress(pixels, .readOnly)
		var hash: UInt64 = 0xcbf29ce484222325
		if let base = CVPixelBufferGetBaseAddress(pixels) {
			let row = CVPixelBufferGetBytesPerRow(pixels), width = CVPixelBufferGetWidth(pixels) * 4
			for y in 0..<CVPixelBufferGetHeight(pixels) {
				let line = base.advanced(by: y * row).assumingMemoryBound(to: UInt64.self)
				for x in 0..<width / 8 {
					hash = (hash ^ line[x]) &* 0x100000001b3
				}
			}
		}
		CVPixelBufferUnlockBaseAddress(pixels, .readOnly)
		all.append(Frame(at: Double(shown) * timebase, dirty: dirty, changed: hash != lastHash))
		lastHash = hash
	}

	func stream(_ stream: SCStream, didStopWithError error: Error) {
		FileHandle.standardError.write("extfps: stream stopped: \(error.localizedDescription)\n".data(using: .utf8)!)
	}

	func snapshot(_ count: Count) -> [Double] {
		lock.lock()
		defer { lock.unlock() }
		let kept = count == .pixels ? all.filter(\.changed) : count == .dirty ? all.filter(\.dirty) : all
		return kept.map(\.at)
	}
}

// GPU busy % of the whole GPU, as Activity Monitor's GPU History
func deviceUtilization() -> Double? {
	let accel = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"))
	guard accel != 0 else { return nil }
	defer { IOObjectRelease(accel) }
	let stats = IORegistryEntryCreateCFProperty(accel, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
		.takeRetainedValue() as? [String: Any]
	return (stats?["Device Utilization %"] as? NSNumber)?.doubleValue
}

// GPU time a process has used, in seconds: the sum over its Metal user clients, as Activity
// Monitor's GPU column
func gpuSeconds(of pid: pid_t) -> Double? {
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
					for u in usage {
						total += (u["accumulatedGPUTime"] as? NSNumber)?.uint64Value ?? 0
					}
				}
				IOObjectRelease(child)
			}
			IOObjectRelease(children)
		}
		IOObjectRelease(accel)
	}
	return found ? Double(total) / 1e9 : nil
}

// CPU seconds and physical footprint of a process of the same user, no root needed
func usage(of pid: pid_t) -> (cpu: Double, footprint: UInt64)? {
	var info = rusage_info_v4()
	let r = withUnsafeMutablePointer(to: &info) {
		$0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
	}
	guard r == 0 else { return nil }
	return (Double(info.ri_user_time + info.ri_system_time) * timebase, info.ri_phys_footprint)
}

// IOReport's Energy Model channels, from the private libIOReport, as tools that read power
// without root do. Nil when the library or the group is missing.
final class Power {
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
	private var lastAt: Double

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
		lastAt = hostSeconds()
	}

	// Watts per channel since the last call
	func watts() -> [String: Double] {
		guard let now = sample(subscription, channels, nil)?.takeRetainedValue() else { return [:] }
		let at = hostSeconds()
		defer { last = now; lastAt = at }
		guard let diff = delta(last, now, nil)?.takeRetainedValue() as? [String: Any],
		      let list = diff["IOReportChannels"] as? [CFDictionary], at > lastAt else { return [:] }
		var out: [String: Double] = [:]
		for ch in list {
			guard let n = name(ch)?.takeUnretainedValue() as String? else { continue }
			let label = unit(ch)?.takeUnretainedValue() as String? ?? ""
			let scale = label == "mJ" ? 1e-3 : label == "uJ" ? 1e-6 : label == "nJ" ? 1e-9 : 0
			out[n, default: 0] += Double(integer(ch, 0)) * scale / (at - lastAt)
		}
		return out
	}
}

let thermalNames = ["nominal", "fair", "serious", "critical"]

func pick(_ o: Options) async throws -> SCWindow {
	let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
	let candidates = content.windows.filter {
		if o.window != 0 { return $0.windowID == o.window }
		if let t = o.title { return $0.title?.contains(t) == true && $0.windowLayer < 24 }
		return $0.owningApplication?.processID == o.pid && $0.windowLayer < 24
	}
	guard let w = candidates.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
		throw NSError(domain: "extfps", code: 1, userInfo: [NSLocalizedDescriptionKey: "no on-screen window for that pid, id or title"])
	}
	return w
}

func run() async {
	var o = parse()
	guard CGPreflightScreenCaptureAccess() else {
		print("extfps: Screen Recording is off for the app that runs this tool: System Settings > Privacy & Security > Screen & System Audio Recording")
		exit(3)
	}
	let window: SCWindow
	do {
		window = try await pick(o)
	} catch {
		print("extfps: \(error.localizedDescription)")
		exit(4)
	}
	if o.pid == 0 { o.pid = window.owningApplication?.processID ?? 0 }
	let config = SCStreamConfiguration()
	let aspect = window.frame.height / max(window.frame.width, 1)
	config.width = o.size
	config.height = max(2, Int((Double(o.size) * aspect).rounded()))
	config.minimumFrameInterval = .zero
	config.queueDepth = 8
	config.showsCursor = false
	config.pixelFormat = kCVPixelFormatType_32BGRA
	let frames = Frames()
	let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: window), configuration: config, delegate: frames)
	let queue = DispatchQueue(label: "extfps.frames", qos: .userInteractive)
	do {
		try stream.addStreamOutput(frames, type: .screen, sampleHandlerQueue: queue)
		try await stream.startCapture()
	} catch {
		print("extfps: capture failed: \(error.localizedDescription)")
		exit(5)
	}
	let power = Power()
	let me = getpid()
	let selfStart = usage(of: me)?.cpu ?? 0
	let start = hostSeconds()
	var lastGPU = gpuSeconds(of: o.pid), lastCPU = usage(of: o.pid)?.cpu, lastAt = start
	print("extfps: window \(window.windowID) of pid \(o.pid) \"\(window.title ?? "")\", \(Int(window.frame.width))x\(Int(window.frame.height)) pt, capture \(config.width)x\(config.height)")
	while hostSeconds() - start < o.seconds {
		try? await Task.sleep(nanoseconds: 1_000_000_000)
		let now = hostSeconds()
		let t = frames.snapshot(o.count)
		let second = t.filter { $0 > now - 1 }
		let recent = Array(t.suffix(601))
		let intervals = zip(recent.dropFirst(), recent).map { $0 - $1 }
		let gpu = gpuSeconds(of: o.pid), cpu = usage(of: o.pid)
		let span = now - lastAt
		var line = String(format: "fps %5.1f  1%%low %5.1f  frame %5.2f ms", Double(second.count), lowOnePercent(intervals),
		                  intervals.isEmpty ? 0 : intervals.suffix(60).reduce(0, +) / Double(min(60, intervals.count)) * 1000)
		line += String(format: "  gpu %3.0f%%", deviceUtilization() ?? -1)
		if let g = gpu, let l = lastGPU { line += String(format: "  gpu(pid) %3.0f%%", (g - l) / span * 100) }
		if let c = cpu, let l = lastCPU { line += String(format: "  cpu %3.0f%%  ram %.0f MB", (c.cpu - l) / span * 100, Double(c.footprint) / 1e6) }
		line += "  thermal \(thermalNames[ProcessInfo.processInfo.thermalState.rawValue])"
		if let w = power?.watts(), !w.isEmpty {
			// Without root, macOS 27 reports the CPU channels as 0
			let cpuW = w["CPU Energy"] ?? 0
			line += String(format: "  power gpu %.2f W", w["GPU Energy"] ?? 0)
			if cpuW > 0 { line += String(format: " cpu %.2f W", cpuW) }
		}
		if !o.quiet { print(line) }
		lastGPU = gpu
		lastCPU = cpu?.cpu
		lastAt = now
		if usage(of: o.pid) == nil { break }
	}
	try? await stream.stopCapture()
	let t = frames.snapshot(o.count).sorted()
	let intervals = zip(t.dropFirst(), t).map { $0 - $1 }
	let elapsed = hostSeconds() - start
	let mean = t.count > 1 ? Double(t.count - 1) / (t.last! - t.first!) : 0
	let selfCPU = ((usage(of: me)?.cpu ?? 0) - selfStart) / elapsed * 100
	for c in [Frames.Count.all, .dirty, .pixels] {
		let f = frames.snapshot(c)
		print(String(format: "count %@ %d frames %.2f fps", c.rawValue, f.count, f.count > 1 ? Double(f.count - 1) / (f.last! - f.first!) : 0))
	}
	print(String(format: "summary frames %d other %d mean %.2f fps 1%%low %.2f fps over %.1f s; extfps cpu %.2f %%",
	             t.count, frames.other, mean, lowOnePercent(intervals), elapsed, selfCPU))
	if let path = o.times {
		try? t.map { String(format: "%.6f", $0) }.joined(separator: "\n").appending("\n").write(toFile: path, atomically: true, encoding: .utf8)
	}
	exit(0)
}

// ScreenCaptureKit needs a WindowServer connection, which NSApplication opens; no Dock icon, no focus
NSApplication.shared.setActivationPolicy(.prohibited)
Task { await run() }
dispatchMain()
