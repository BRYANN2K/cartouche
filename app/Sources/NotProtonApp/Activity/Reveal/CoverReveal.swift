
import AppKit
import MetalKit
import SwiftUI

enum CoverReveal {
    struct Progress: Equatable, Sendable {
        var fraction: Double
        var finishedAt: Date?
        var animating = true
    }

    static func usesShader(reduceMotion: Bool) -> Bool {
        !reduceMotion && RevealRenderer.shared != nil
    }
}

struct RevealCover: View {
    let game: Game
    var override: URL?
    let progress: CoverReveal.Progress

    @Environment(\.covers) private var covers
    @State private var loaded: CoverLoader.Loaded?

    var body: some View {
        Group {
            if let loaded, case .image = loaded.art,
               let color = loaded.color, let gray = loaded.gray, let cg = loaded.colorCG {
                RevealImage(color: color, image: cg, gray: gray, progress: progress)
            }
        }
        .task(id: "\(game.id)|\(override?.path ?? "")") {
            loaded = nil
            loaded = await CoverLoader.load(game, kind: .cover, override: override, covers: covers, gray: true)
        }
        .accessibilityHidden(true)
    }
}

extension EnvironmentValues {
    // Offscreen snapshots cannot capture Metal layers, so they ask for the still split
    @Entry var revealStill = false
}

struct RevealImage: View {
    let color: NSImage
    let image: CGImage
    let gray: NSImage
    let progress: CoverReveal.Progress

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.revealStill) private var still

    var body: some View {
        if !still, CoverReveal.usesShader(reduceMotion: reduceMotion) {
            MetalReveal(image: image, progress: progress)
        } else {
            StaticReveal(color: color, gray: gray, fraction: progress.fraction)
        }
    }
}

struct StaticReveal: View {
    let color: NSImage
    let gray: NSImage
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Image(nsImage: gray).resizable().aspectRatio(contentMode: .fill)
                Image(nsImage: color).resizable().aspectRatio(contentMode: .fill)
                    .mask(alignment: .bottom) {
                        Rectangle().frame(height: proxy.size.height * min(1, max(0, fraction)))
                    }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
    }
}

struct MetalReveal: NSViewRepresentable {
    let image: CGImage
    let progress: CoverReveal.Progress

    func makeCoordinator() -> RevealDrawer { RevealDrawer() }

    func makeNSView(context: Context) -> MTKView {
        let view = Self.view(drawer: context.coordinator)
        context.coordinator.update(image: image, progress: progress)
        return view
    }

    static func view(drawer: RevealDrawer) -> MTKView {
        let view = MTKView(frame: .zero, device: RevealRenderer.shared?.device)
        view.colorPixelFormat = RevealRenderer.pixelFormat
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 30
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.layer?.isOpaque = true
        view.delegate = drawer
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.update(image: image, progress: progress)
        view.isPaused = !progress.animating
        if !progress.animating { view.draw() }
    }

    static func dismantleNSView(_ view: MTKView, coordinator: RevealDrawer) {
        view.isPaused = true
        view.delegate = nil
    }
}

final class RevealDrawer: NSObject, MTKViewDelegate {

    private var image: CGImage?
    private var target = CoverReveal.Progress(fraction: 0)
    // Eases toward the target, 6% of the gap per sixtieth of a second like the mockup
    private var shown: Double?
    private let start = CACurrentMediaTime()
    private var lastDraw = CACurrentMediaTime()
    private(set) var frames = 0
    var drawsWhenOccluded = false

    func update(image: CGImage, progress: CoverReveal.Progress) {
        self.image = image
        target = progress
        if shown == nil { shown = progress.fraction }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        if !drawsWhenOccluded, let window = view.window, !window.occlusionState.contains(.visible) { return }
        guard let renderer = RevealRenderer.shared, let image, let texture = renderer.texture(for: image),
              let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let buffer = renderer.queue.makeCommandBuffer() else { return }
        let now = CACurrentMediaTime()
        let elapsed = now - lastDraw
        lastDraw = now
        let value = uniforms(size: view.drawableSize, image: image, now: now, elapsed: elapsed)
        renderer.encode(buffer, pass: pass, texture: texture, uniforms: value)
        buffer.present(drawable)
        buffer.commit()
        frames += 1
    }

    func uniforms(size: CGSize, image: CGImage, now: CFTimeInterval, elapsed: CFTimeInterval) -> RevealUniforms {
        var current = shown ?? target.fraction
        current += (target.fraction - current) * min(1, elapsed * 3.6)
        shown = current
        var u = RevealUniforms()
        u.time = Float(now - start)
        u.motion = 1
        if let finished = target.finishedAt {
            let done = Date().timeIntervalSince(finished) / (ActivityCenter.finishFlash / .seconds(1))
            u.progress = 1
            u.finish = Float(max(0, 1 - min(1, done)))
        } else {
            u.progress = Float(current)
        }
        u.size = SIMD2(Float(size.width), Float(size.height))
        u.crop = RevealRenderer.crop(image: CGSize(width: image.width, height: image.height), target: size)
        return u
    }
}
