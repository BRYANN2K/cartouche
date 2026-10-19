import AppKit
import Darwin
import Foundation
import MetalKit
import Testing

@testable import NotProtonApp

// Frame rate and CPU of the reveal as the app draws it: MTKViews driven by the
// display link in a window, for 5 seconds. Runs only with CARTOUCHE_BENCH=1, since
// a CI runner without a display has no display link to measure.
@MainActor
@Suite("Cover reveal performance", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["CARTOUCHE_BENCH"] == "1" && RevealRenderer.shared != nil,
                "set CARTOUCHE_BENCH=1 on a Mac with a display"))
struct RevealBenchTests {

    static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    func measure(covers: Int, seconds: Double = 5) async throws -> (fps: Double, cpu: Double, idle: Double) {
        let image = revealFixtureCover(width: 600, height: 900)
        // The grid's cover size: about 180 by 270 points on a Retina screen
        let size = CGSize(width: 180, height: 270)
        let window = NSWindow(contentRect: CGRect(x: 80, y: 80, width: size.width * CGFloat(covers) + 20, height: size.height + 20),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        let root = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = root

        // Idle first: the same window without any reveal
        window.orderFrontRegardless()
        try await Task.sleep(for: .seconds(1))
        let idleStart = Self.cpuSeconds(), idleWall = Date()
        try await Task.sleep(for: .seconds(seconds))
        let idle = (Self.cpuSeconds() - idleStart) / Date().timeIntervalSince(idleWall)

        var drawers: [RevealDrawer] = []
        var views: [MTKView] = []
        for i in 0..<covers {
            let drawer = RevealDrawer()
            drawer.drawsWhenOccluded = true
            drawer.update(image: image, progress: CoverReveal.Progress(fraction: 0.5))
            let view = MetalReveal.view(drawer: drawer)
            views.append(view)
            view.frame = CGRect(x: 10 + CGFloat(i) * size.width, y: 10, width: size.width, height: size.height)
            root.addSubview(view)
            drawers.append(drawer)
        }
        // A test process gets no display link, so a 60 Hz timer on the main queue asks
        // each view to draw, the same call the display link makes in the app
        for view in views { view.isPaused = true }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .nanoseconds(16_666_667), leeway: .microseconds(500))
        timer.setEventHandler { MainActor.assumeIsolated { for view in views { view.draw() } } }
        timer.resume()
        defer { timer.cancel() }
        try await Task.sleep(for: .seconds(1))
        let frames0 = drawers.map(\.frames), cpu0 = Self.cpuSeconds(), wall0 = Date()
        try await Task.sleep(for: .seconds(seconds))
        let wall = Date().timeIntervalSince(wall0)
        let cpu = (Self.cpuSeconds() - cpu0) / wall
        let fps = zip(drawers.map(\.frames), frames0).map { Double($0 - $1) / wall }.min() ?? 0
        window.orderOut(nil)
        window.close()
        return (fps, cpu, idle)
    }

    @Test("One revealing cover: frames per second and the process's CPU")
    func oneCover() async throws {
        let result = try await measure(covers: 1)
        print(String(format: "reveal bench, 1 cover: %.1f fps, CPU %.2f%% (idle window %.2f%%)",
                     result.fps, result.cpu * 100, result.idle * 100))
        #expect(result.fps >= 55)
        #expect(result.cpu - result.idle < 0.05)
    }

    @Test("Three revealing covers at once")
    func threeCovers() async throws {
        let result = try await measure(covers: 3)
        print(String(format: "reveal bench, 3 covers: %.1f fps each, CPU %.2f%% (idle window %.2f%%)",
                     result.fps, result.cpu * 100, result.idle * 100))
        #expect(result.fps >= 55)
    }
}
