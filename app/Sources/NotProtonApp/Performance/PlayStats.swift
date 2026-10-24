
import Foundation

struct FrameSample: Equatable, Sendable {
    let time: Int
    let frames: Int
    let frontmost: Bool
    var width = 0
    var height = 0

    // "# cartouche-fps 1 ..." starts a file; each other line is "<time> <frames> <frontmost> <width> <height>"
    static func parse(_ text: String) -> [FrameSample] {
        text.split(separator: "\n").compactMap { line in
            guard !line.hasPrefix("#") else { return nil }
            let fields = line.split(separator: " ").map { Int($0) }
            guard fields.count == 5, let time = fields[0], let frames = fields[1], let front = fields[2],
                  let width = fields[3], let height = fields[4], frames >= 0 else { return nil }
            return FrameSample(time: time, frames: frames, frontmost: front != 0, width: width, height: height)
        }
    }
}

struct PlaySetup: Hashable, Sendable {
    var runnerID: String
    var translation: GameSetupChoice.Translation
    var backend: GraphicsBackend?

    // Sessions recorded before the run script wrote the setup get this runner
    static let unknownRunnerID = "unknown"
}

enum PlayStats {

    // Shaders compile and assets stream in while a game warms up
    static let warmUpSeconds = 30
    // A second with fewer frames is a loading screen or a stall, not play
    static let loadingBelow = 5
    // A setup is only called the best once it has this much measured play behind it
    static let minimumSampleSeconds = 10 * 60
    static let minimumSampleSessions = 2

    static func counted(_ samples: [FrameSample]) -> [Bool] {
        guard let start = samples.first?.time else { return [] }
        return samples.map { $0.time - start >= warmUpSeconds && $0.frontmost && $0.frames >= loadingBelow }
    }

    struct Measured: Equatable, Sendable {
        var seconds = 0
        var frames = 0
        var histogram: [Int: Int] = [:]
        var width: Int?
        var height: Int?

        var average: Double? { seconds > 0 ? Double(frames) / Double(seconds) : nil }
        var low1: Double? { PlayStats.low1(histogram) }
    }

    static func measure(_ samples: [FrameSample]) -> Measured {
        var out = Measured()
        var sizes: [Int: Int] = [:]
        for (sample, counts) in zip(samples, counted(samples)) where counts {
            out.seconds += 1
            out.frames += sample.frames
            out.histogram[sample.frames, default: 0] += 1
            if sample.width > 0, sample.height > 0 { sizes[sample.width << 20 | sample.height, default: 0] += 1 }
        }
        if let size = sizes.max(by: { ($0.value, $1.key) < ($1.value, $0.key) })?.key {
            out.width = size >> 20
            out.height = size & 0xFFFFF
        }
        return out
    }

    // The mean of the slowest 1% of counted seconds, at least one second
    static func low1(_ histogram: [Int: Int]) -> Double? {
        let total = histogram.values.reduce(0, +)
        guard total > 0 else { return nil }
        let wanted = max(1, total / 100)
        var taken = 0, sum = 0
        for (fps, count) in histogram.sorted(by: { $0.key < $1.key }) {
            let take = min(count, wanted - taken)
            taken += take
            sum += take * fps
            if taken == wanted { break }
        }
        return Double(sum) / Double(wanted)
    }

    // Each average counts for as long as it was measured, so a short test does not weigh as hours of play.
    static func weightedAverage(_ parts: [(average: Double, seconds: Int)]) -> Double? {
        let seconds = parts.reduce(0) { $0 + $1.seconds }
        guard seconds > 0 else { return nil }
        return parts.reduce(0) { $0 + $1.average * Double($1.seconds) } / Double(seconds)
    }

    static func merge(_ histograms: [[Int: Int]]) -> [Int: Int] {
        histograms.reduce(into: [:]) { out, h in out.merge(h, uniquingKeysWith: +) }
    }
}

struct SetupPlay: Equatable, Sendable, Identifiable {
    let setup: PlaySetup
    let runnerName: String
    let average: Double?
    let low1: Double?
    let measuredSeconds: Int
    let played: TimeInterval
    let sessions: Int
    let measuredSessions: Int
    let lastPlayed: Date
    var width: Int?
    var height: Int?

    var id: PlaySetup { setup }

    // Enough measured play for the average to say something, not just one lucky run
    var meetsMinimumSample: Bool {
        measuredSeconds >= PlayStats.minimumSampleSeconds && measuredSessions >= PlayStats.minimumSampleSessions
    }
}

struct GamePlay: Equatable, Sendable {
    let average: Double?
    let low1: Double?
    let played: TimeInterval
    let lastPlayed: Date
    let setups: [SetupPlay]
    let measurementRefused: Bool

    var measuredSetups: [SetupPlay] { setups.filter { $0.average != nil } }
    // Setups with too little measured play never get the tag; ties fall to the better
    // 1% low, then the longer sample and the more recent session
    var best: SetupPlay? { setups.first { $0.meetsMinimumSample } }

    static func summarize(_ sessions: [StoredSession]) -> GamePlay? {
        guard let latest = sessions.max(by: { $0.started < $1.started }) else { return nil }
        let groups = Dictionary(grouping: sessions, by: \.setup)
        let setups = groups.map { setup, runs in
            let measured = runs.filter { $0.measured.seconds > 0 }
            let latestMeasured = measured.max { $0.started < $1.started }
            return SetupPlay(
                setup: setup,
                runnerName: runs.max(by: { $0.started < $1.started })!.runnerName,
                average: PlayStats.weightedAverage(measured.compactMap { s in s.measured.average.map { ($0, s.measured.seconds) } }),
                low1: PlayStats.low1(PlayStats.merge(measured.map(\.measured.histogram))),
                measuredSeconds: measured.reduce(0) { $0 + $1.measured.seconds },
                played: runs.reduce(0) { $0 + $1.duration },
                sessions: runs.count,
                measuredSessions: measured.count,
                lastPlayed: runs.map(\.ended).max() ?? latest.ended,
                width: latestMeasured?.measured.width,
                height: latestMeasured?.measured.height)
        }
        .sorted { (a: SetupPlay, b: SetupPlay) in
            if a.meetsMinimumSample != b.meetsMinimumSample { return a.meetsMinimumSample }
            let key = { (s: SetupPlay) in
                (s.average ?? -1, s.low1 ?? -1, s.measuredSeconds, s.lastPlayed.timeIntervalSince1970)
            }
            let id = { (s: SetupPlay) in
                "\(s.setup.runnerID)\(s.setup.backend?.rawValue ?? "")\(s.setup.translation)"
            }
            return key(a) == key(b) ? id(a) < id(b) : key(a) > key(b)
        }
        let measured = sessions.filter { $0.measured.seconds > 0 }
        return GamePlay(
            average: PlayStats.weightedAverage(measured.compactMap { s in s.measured.average.map { ($0, s.measured.seconds) } }),
            low1: PlayStats.low1(PlayStats.merge(measured.map(\.measured.histogram))),
            played: sessions.reduce(0) { $0 + $1.duration },
            lastPlayed: latest.ended,
            setups: setups,
            measurementRefused: latest.measurement == .refused)
    }
}
