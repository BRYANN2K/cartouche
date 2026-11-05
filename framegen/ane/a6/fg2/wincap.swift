// Captures one window of a process with ScreenCaptureKit, after moving it to the Mac's built-in
// screen, without activating anything. Writes to stdout, per frame: the display time in seconds
// (float64) then width x height BGRA bytes.
// Usage: wincap --screen | wincap --check | wincap <pid> <seconds> <width> <height> [fps] [title bar height in points, default 32]
//        [share of the window kept from its bottom left, default 1: 0.5 for GL games drawn at 1x on Retina]
import AppKit
import ApplicationServices
import CoreMedia
import ScreenCaptureKit

let args = CommandLine.arguments
// wincap --screen: the built-in screen's index in NSScreen.screens (Godot's --screen), -1 if none
if args.count == 2 && args[1] == "--screen" {
	let index = NSScreen.screens.firstIndex(where: {
		($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDisplayIsBuiltin($0.uint32Value) != 0 } ?? false
	})
	print(index ?? -1)
	exit(0)
}
// wincap --check: Screen Recording and Accessibility granted, without asking
if args.count == 2 && args[1] == "--check" {
	let capture = CGPreflightScreenCaptureAccess(), ax = AXIsProcessTrusted()
	print("screen recording \(capture ? "granted" : "missing"), accessibility \(ax ? "granted" : "missing")")
	exit(capture && ax ? 0 : 1)
}
guard args.count >= 5, let pid = pid_t(args[1]), let seconds = Double(args[2]), let width = Int(args[3]),
	let height = Int(args[4]) else {
	FileHandle.standardError.write("usage: wincap <pid> <seconds> <width> <height> [fps]\n".data(using: .utf8)!)
	exit(2)
}
let fps = args.count > 5 ? Int32(args[5]) ?? 60 : 60
let top = args.count > 6 ? Double(args[6]) ?? 32 : 32
let keep = args.count > 7 ? Double(args[7]) ?? 1 : 1

func say(_ s: String) { FileHandle.standardError.write("wincap: \(s)\n".data(using: .utf8)!) }

func builtinBounds() -> CGRect? {
	var n: UInt32 = 0
	CGGetActiveDisplayList(0, nil, &n)
	var ids = [CGDirectDisplayID](repeating: 0, count: Int(n))
	CGGetActiveDisplayList(n, &ids, &n)
	return ids.first(where: { CGDisplayIsBuiltin($0) != 0 }).map { CGDisplayBounds($0) }
}

func moveToBuiltin() -> Bool {
	guard let screen = builtinBounds() else { say("no built-in screen"); return false }
	let app = AXUIElementCreateApplication(pid)
	var value: CFTypeRef?
	guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
		let windows = value as? [AXUIElement], !windows.isEmpty else { return false }
	for window in windows {
		var point = CGPoint(x: screen.minX + 16, y: screen.minY + 40)
		let position = AXValueCreate(.cgPoint, &point)!
		AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position)
	}
	return true
}

final class Sink: NSObject, SCStreamOutput {
	let out = FileHandle.standardOutput
	var frames = 0, first = -1.0, last = 0.0
	let width: Int, height: Int, row: Int
	var buffer: [UInt8]

	init(_ width: Int, _ height: Int) {
		self.width = width
		self.height = height
		row = width * 4
		buffer = [UInt8](repeating: 0, count: width * height * 4 + 8)
	}

	func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
		guard type == .screen, let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
			as? [[SCStreamFrameInfo: Any]], let info = attachments.first,
			let raw = info[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
			let image = CMSampleBufferGetImageBuffer(sample) else { return }
		let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds
		if first < 0 { first = t }
		last = t
		CVPixelBufferLockBaseAddress(image, .readOnly)
		let base = CVPixelBufferGetBaseAddress(image)!.assumingMemoryBound(to: UInt8.self)
		let stride = CVPixelBufferGetBytesPerRow(image)
		let w = min(CVPixelBufferGetWidth(image), width), h = min(CVPixelBufferGetHeight(image), height)
		buffer.withUnsafeMutableBytes { dst in
			var time = t - first
			memcpy(dst.baseAddress!, &time, 8)
			for y in 0..<h { memcpy(dst.baseAddress! + 8 + y * row, base + y * stride, w * 4) }
		}
		CVPixelBufferUnlockBaseAddress(image, .readOnly)
		out.write(Data(buffer))
		frames += 1
	}
}

let sink = Sink(width, height)
var stream: SCStream?

var listError = ""
func shareable() async -> SCShareableContent? {
	do { return try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) } catch {
		if listError != error.localizedDescription { listError = error.localizedDescription; say("window list: \(listError)") }
		return nil
	}
}

func findWindow(until deadline: Date) async -> SCWindow? {
	while Date() < deadline {
		if moveToBuiltin(), let content = await shareable() {
			let screen = builtinBounds() ?? .null
			if let window = content.windows.filter({
				$0.owningApplication?.processID == pid && $0.frame.width >= 320 && $0.frame.height >= 200
					&& screen.intersects($0.frame)
			}).max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) {
				return window
			}
		}
		try? await Task.sleep(nanoseconds: 500_000_000)
	}
	return nil
}

// A game may replace its first window (size or mode change): no frames in 3 s means try again
_ = Task {
	let deadline = Date().addingTimeInterval(90)
	for _ in 0..<4 {
		guard let window = await findWindow(until: deadline) else { break }
		say("window \(Int(window.frame.width))x\(Int(window.frame.height)) at \(window.frame.origin)")
		let config = SCStreamConfiguration()
		config.width = width
		config.height = height
		config.sourceRect = CGRect(x: 0, y: top + (window.frame.height - top) * (1 - keep), width: window.frame.width * keep,
			height: (window.frame.height - top) * keep)
		config.minimumFrameInterval = CMTime(value: 1, timescale: fps)
		config.pixelFormat = kCVPixelFormatType_32BGRA
		config.showsCursor = false
		config.queueDepth = 8
		config.capturesAudio = false
		let s = SCStream(filter: SCContentFilter(desktopIndependentWindow: window), configuration: config, delegate: nil)
		guard (try? s.addStreamOutput(sink, type: .screen, sampleHandlerQueue: DispatchQueue(label: "wincap"))) != nil,
			(try? await s.startCapture()) != nil else { continue }
		stream = s
		try? await Task.sleep(nanoseconds: 3_000_000_000)
		if sink.frames == 0 {
			try? await s.stopCapture()
			say("no frames from that window, looking again")
			continue
		}
		try? await Task.sleep(nanoseconds: UInt64(max(0, seconds - 3) * 1e9))
		try? await s.stopCapture()
		let span = sink.last - sink.first
		say(String(format: "%d frames over %.2f s (%.1f fps)", sink.frames, span, span > 0 ? Double(sink.frames - 1) / span : 0))
		exit(0)
	}
	say("no frames from a window of \(pid) on the built-in screen")
	exit(1)
}
RunLoop.main.run()
