import Foundation
import Testing

@testable import NotProtonApp

// The counter's view of a frame-time series: one line per wall second once the first
// frame starts the sampler, holding that second's frame count, like a samples-<pid> file.
private enum SyntheticCounter {
    static func samples(_ frameTimes: [Double], frontmost: (Int) -> Bool = { _ in true }) -> [FrameSample] {
        guard let first = frameTimes.first else { return [] }
        var counts: [Int: Int] = [:]
        var last = 0
        for time in frameTimes {
            let second = max(0, Int(time - first))
            counts[second, default: 0] += 1
            last = max(last, second)
        }
        return (0...last).map { second in
            FrameSample(time: Int(first) + second + 1, frames: counts[second] ?? 0,
                        frontmost: frontmost(second))
        }
    }

    // `rate` presented frames per second for `seconds`, starting at `start`
    static func frames(rate: Double, seconds: Int, start: Double, jitter: Double = 0) -> [Double] {
        (0..<Int((rate * Double(seconds)).rounded())).map { i in
            let time = start + Double(i) / rate
            return jitter == 0 ? time : time + jitter * sin(Double(i) * 12.9898)
        }
    }
}

@Suite("Performance frame-time sampling")
struct PerformanceFrameTimingTests {

    static let start = 1_790_000_000.0

    @Test("A locked 60 fps scene counts at 60, minus the 30 seconds of warm-up")
    func locked() {
        let samples = SyntheticCounter.samples(
            SyntheticCounter.frames(rate: 60, seconds: 300, start: Self.start))
        #expect(samples.count == 300)
        #expect(samples.allSatisfy { $0.frames == 60 })
        let measured = PlayStats.measure(samples)
        #expect(measured.seconds == 270)
        #expect(measured.average == 60)
        #expect(measured.low1 == 60)
    }

    @Test("Jitter in the frame times shifts single frames between seconds, the average stays")
    func jittered() {
        let samples = SyntheticCounter.samples(
            SyntheticCounter.frames(rate: 60, seconds: 300, start: Self.start, jitter: 0.004))
        let counted = zip(samples, PlayStats.counted(samples)).filter { $0.1 }.map { $0.0 }
        #expect(counted.allSatisfy { (58...62).contains($0.frames) })
        let measured = PlayStats.measure(samples)
        #expect(measured.seconds == 270)
        #expect(abs((measured.average ?? 0) - 60) < 0.5)
    }

    @Test("A rate the per-second lines cannot hold still measures within a frame")
    func accuracy() {
        // 73.3 fps lands as seconds of 73 and 74 frames; the average comes back
        for rate in [73.3, 144.0, 23.98] {
            let times = SyntheticCounter.frames(rate: rate, seconds: 120, start: Self.start)
            let measured = PlayStats.measure(SyntheticCounter.samples(times))
            let trueRate = Double(times.count) / 120
            #expect(abs((measured.average ?? 0) - trueRate) < 1, "\(rate) fps")
        }
    }

    @Test("A slow start is warm-up and a pause is seconds with no frames, neither counts")
    func pauseAndWarmUp() {
        // 20 fps for the first 30 s (shader compiles), 60 fps after, 5 s paused at 100-104
        var times = SyntheticCounter.frames(rate: 20, seconds: 30, start: Self.start)
        times += SyntheticCounter.frames(rate: 60, seconds: 70, start: Self.start + 30)
        times += SyntheticCounter.frames(rate: 60, seconds: 100, start: Self.start + 105)
        let samples = SyntheticCounter.samples(times)
        // One line per second for the 205-second run, the pause included
        #expect(samples.count == 205)
        #expect(samples[100..<105].allSatisfy { $0.frames == 0 })
        let counted = PlayStats.counted(samples)
        // Warm-up keeps the slow start out; the five paused seconds are under the floor
        #expect(counted[0..<30].allSatisfy { !$0 })
        #expect(counted[100..<105].allSatisfy { !$0 })
        let measured = PlayStats.measure(samples)
        #expect(measured.seconds == 205 - 30 - 5)
        #expect(measured.average == 60)
    }

    @Test("Minutes in the background do not count even while frames arrive")
    func background() {
        let times = SyntheticCounter.frames(rate: 60, seconds: 600, start: Self.start)
        let samples = SyntheticCounter.samples(times) { !(200..<320).contains($0) }
        let measured = PlayStats.measure(samples)
        #expect(measured.seconds == 600 - 30 - 120)
        #expect(zip(samples, PlayStats.counted(samples)).allSatisfy { $0.0.frontmost || !$0.1 })
    }

    @Test("The 1% low comes out of the seconds the frame times land in")
    func lowOnePercent() {
        var times = SyntheticCounter.frames(rate: 60, seconds: 500, start: Self.start)
        times += SyntheticCounter.frames(rate: 30, seconds: 10, start: Self.start + 500)
        times += SyntheticCounter.frames(rate: 60, seconds: 530, start: Self.start + 510)
        let measured = PlayStats.measure(SyntheticCounter.samples(times))
        // 1,010 counted seconds, the ten slowest at 30 fps: 1% is 10 seconds
        #expect(measured.seconds == 1010)
        #expect(measured.low1 == 30)
    }
}
