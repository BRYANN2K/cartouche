import AppKit

// The app's half of a session's context while the game runs: other apps' CPU on average, the worst heat,
// the screen. The run script writes the rest as the game starts.
struct SessionContextRecorder: Equatable, Sendable {
    var othersCPU: [Double] = []
    var thermal = 0
    var display: String?

    static let thermalNames = ["nominal", "fair", "serious", "critical"]

    mutating func add(othersCPU value: Double, thermal state: Int) {
        if value.isFinite { othersCPU.append(value) }
        thermal = max(thermal, min(3, max(0, state)))
    }

    var lines: [String] {
        var out: [String] = []
        if !othersCPU.isEmpty {
            out.append("others_cpu_avg=\(Int((othersCPU.reduce(0, +) / Double(othersCPU.count)).rounded()))")
        }
        out.append("thermal_max=\(Self.thermalNames[thermal])")
        if let display { out.append("display=\(display)") }
        return out
    }

    @MainActor
    static func display(_ screen: NSScreen? = NSScreen.main) -> String? {
        screen.map { "\(Int($0.frame.width))×\(Int($0.frame.height)) @ \($0.maximumFramesPerSecond) Hz" }
    }

    // Into every launch folder whose game still runs: a session without its end, started since
    static func write(_ lines: [String], incoming: URL, since: Date) {
        let files = FileManager.default
        for folder in (try? files.contentsOfDirectory(at: incoming, includingPropertiesForKeys: nil)) ?? [] {
            guard let text = try? String(contentsOf: folder.appending(path: PerformanceIncoming.sessionFile), encoding: .utf8),
                  !text.contains("\nended="),
                  let started = text.split(separator: "\n").first(where: { $0.hasPrefix("started=") })
                      .flatMap({ TimeInterval($0.dropFirst(8)) }),
                  started >= since.timeIntervalSince1970 else { continue }
            let target = folder.appending(path: PerformanceIncoming.appContextFile)
            try? Data((lines.joined(separator: "\n") + "\n").utf8).write(to: target, options: .atomic)
        }
    }
}
