// The mockup's WebGL cover reveal in Metal; compiled at runtime because the offline metal tool is an optional Xcode download.

import CoreGraphics
import Foundation
import Metal
import MetalKit

// Matches the shader's U struct: four floats, then a float2 and a float4, 16-byte aligned
struct RevealUniforms: Equatable, Sendable {
    var progress: Float = 0
    // Seconds, for the moving noise; 0 freezes it
    var time: Float = 0
    // Finish ring, from 1 when the download completes down to 0
    var finish: Float = 0
    // 1 draws the embers
    var motion: Float = 1
    // The drawable's size in pixels
    var size: SIMD2<Float> = SIMD2(1, 1)
    // Origin and scale in the texture, so a cover of another shape fills like aspect-fill
    var crop: SIMD4<Float> = SIMD4(0, 0, 1, 1)
}

enum RevealShader {

    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct VOut { float4 position [[position]]; float2 uv; };
    struct U { float P; float t; float F; float M; float2 R; float4 crop; };

    // Two triangles over the whole target; uv is 0,0 at the top left like the texture
    vertex VOut reveal_vertex(uint vid [[vertex_id]]) {
        float2 a = float2((vid & 1) ? 1.0 : -1.0, (vid & 2) ? 1.0 : -1.0);
        VOut o;
        o.position = float4(a, 0.0, 1.0);
        o.uv = float2(a.x * 0.5 + 0.5, 1.0 - (a.y * 0.5 + 0.5));
        return o;
    }

    static float h(float2 p) { return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453); }
    static float n(float2 p) {
        float2 i = floor(p), f = fract(p);
        f = f * f * (3.0 - 2.0 * f);
        return mix(mix(h(i), h(i + float2(1, 0)), f.x), mix(h(i + float2(0, 1)), h(i + float2(1, 1)), f.x), f.y);
    }
    static float fbm(float2 p) {
        float s = 0.0, a = 0.5;
        for (int i = 0; i < 5; i++) { s += a * n(p); p = p * 2.03 + 17.1; a *= 0.5; }
        return s;
    }
    static float field(float2 p, float t) {
        float2 q = float2(fbm(p * 2.2 + float2(0.0, t * 0.12)), fbm(p * 2.2 + float2(5.2, 1.3) - t * 0.09));
        return fbm(p * 2.6 + 2.1 * q + float2(0.0, -t * 0.35));
    }
    static float3 gray(float3 c) { return float3(dot(c, float3(0.299, 0.587, 0.114))); }

    fragment float4 reveal_fragment(VOut in [[stage_in]], constant U& u [[buffer(0)]],
                                    texture2d<float> T [[texture(0)]]) {
        constexpr sampler s(address::clamp_to_edge, filter::linear);
        float2 uv = in.uv;
        float2 tc = u.crop.xy + uv * u.crop.zw;
        float P = u.P, t = u.t, F = u.F;
        float aspect = u.R.x / u.R.y;
        float2 p = float2(uv.x * aspect, uv.y) * 1.6;
        float front = P * 1.18 - 0.09;
        float nf = field(p, t);
        // Below 0 is revealed, above 0 still gray
        float d = (1.0 - uv.y) - front + (nf - 0.5) * 0.42;
        float e = 0.012;
        float2 g = float2(field(p + float2(e, 0), t) - field(p - float2(e, 0), t),
                          field(p + float2(0, e), t) - field(p - float2(0, e), t)) / (2.0 * e);
        float band = exp(-abs(d) * 22.0);
        float2 off = g * 0.010 * band * (1.0 - F);
        float3 col = float3(T.sample(s, tc + off * 1.0).r, T.sample(s, tc + off * 1.6).g, T.sample(s, tc + off * 2.3).b);
        col = mix(col, col * 1.18 + 0.04, band * 0.6);
        float3 base = T.sample(s, tc).rgb;
        float3 g0 = gray(base) * 0.8 * (1.0 - 0.45 * exp(-max(d, 0.0) * 16.0));
        float reveal = 1.0 - smoothstep(-0.004, 0.004, d);
        float3 c = mix(g0, col, reveal);
        float core = 1.0 - smoothstep(0.0, 0.006, abs(d));
        float glow = exp(-abs(d) * 46.0) * (0.75 + 0.25 * sin(t * 6.0 + uv.x * 20.0));
        float3 tint = normalize(T.sample(s, u.crop.xy + float2(uv.x, 1.0 - front) * u.crop.zw).rgb + 0.15) * 1.2;
        c += (tint * glow * 0.8 + float3(1.0, 0.95, 0.85) * core) * (1.0 - F) * step(0.001, P) * step(P, 0.999);
        if (u.M > 0.5) {
            for (int i = 0; i < 26; i++) {
                float fi = float(i), sd = h(float2(fi, 3.1));
                float life = fract(t * (0.22 + 0.25 * sd) + sd * 7.0);
                float2 ep = float2(fract(sd * 13.7 + 0.07 * sin(t * 0.7 + fi)),
                                   1.0 - front - life * 0.32 + (h(float2(fi, 9.0)) - 0.5) * 0.06);
                ep.x += 0.03 * sin(t * 2.0 + fi) * life;
                float r = (1.0 - life) * 0.009 + 0.002;
                float dd = length((uv - ep) * float2(aspect, 1.0));
                c += tint * 1.4 * smoothstep(r, 0.0, dd) * (1.0 - life) * (1.0 - F) * step(0.01, P);
            }
        }
        float ring = exp(-abs(length((uv - 0.5) * float2(aspect, 1.0)) - (1.0 - F) * 0.9) * 26.0) * F;
        c += ring * 0.9 + F * F * 0.25;
        return float4(c, 1.0);
    }
    """
}

// Nil when there is no Metal device or the source does not compile; the static split is used instead.
final class RevealRenderer: @unchecked Sendable {

    static let pixelFormat = MTLPixelFormat.bgra8Unorm

    let device: any MTLDevice
    let queue: any MTLCommandQueue
    let pipeline: any MTLRenderPipelineState
    private let loader: MTKTextureLoader
    private let textures = NSCache<CGImage, TextureBox>()

    private final class TextureBox {
        let texture: any MTLTexture
        init(_ texture: any MTLTexture) { self.texture = texture }
    }

    private static let made: RevealRenderer? = RevealRenderer()

    static var shared: RevealRenderer? { made }

    static func warmUp() {
        Task.detached(priority: .utility) { _ = RevealRenderer.shared }
    }

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        do {
            let options = MTLCompileOptions()
            // The noise hash takes the sine of large numbers, which fast math gets wrong
            options.mathMode = .safe
            let library = try device.makeLibrary(source: RevealShader.source, options: options)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "reveal_vertex")
            descriptor.fragmentFunction = library.makeFunction(name: "reveal_fragment")
            descriptor.colorAttachments[0].pixelFormat = Self.pixelFormat
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            AppLog.note("cover reveal shader unavailable: \(error.localizedDescription)")
            return nil
        }
        self.device = device
        self.queue = queue
        loader = MTKTextureLoader(device: device)
    }

    func texture(for image: CGImage) -> (any MTLTexture)? {
        if let hit = textures.object(forKey: image) { return hit.texture }
        guard let texture = try? loader.newTexture(cgImage: image, options: [
            .SRGB: false, .origin: MTKTextureLoader.Origin.topLeft, .textureUsage: MTLTextureUsage.shaderRead.rawValue,
        ]) else { return nil }
        textures.setObject(TextureBox(texture), forKey: image)
        return texture
    }

    static func crop(image: CGSize, target: CGSize) -> SIMD4<Float> {
        guard image.width > 0, image.height > 0, target.width > 0, target.height > 0 else { return SIMD4(0, 0, 1, 1) }
        let imageAspect = image.width / image.height, targetAspect = target.width / target.height
        if imageAspect > targetAspect {
            let w = targetAspect / imageAspect
            return SIMD4(Float((1 - w) / 2), 0, Float(w), 1)
        }
        let h = imageAspect / targetAspect
        return SIMD4(0, Float((1 - h) / 2), 1, Float(h))
    }

    func encode(_ buffer: any MTLCommandBuffer, pass: MTLRenderPassDescriptor, texture: any MTLTexture, uniforms: RevealUniforms) {
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        var u = uniforms
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&u, length: MemoryLayout<RevealUniforms>.stride, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
    }

    func render(_ image: CGImage, width: Int, height: Int, uniforms: RevealUniforms) -> CGImage? {
        guard let source = texture(for: image) else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.pixelFormat, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let target = device.makeTexture(descriptor: descriptor), let buffer = queue.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        var u = uniforms
        u.size = SIMD2(Float(width), Float(height))
        u.crop = Self.crop(image: CGSize(width: image.width, height: image.height), target: CGSize(width: width, height: height))
        encode(buffer, pass: pass, texture: source, uniforms: u)
        buffer.commit()
        buffer.waitUntilCompleted()

        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        target.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
