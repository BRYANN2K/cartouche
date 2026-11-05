import CartoucheIdentity
import Darwin
import Foundation

// The library's /cartouche-metrics.<pid>, read with its seqlock rule
enum MetricsBlockReader {
    static func name(_ pid: pid_t) -> String { String(format: FG_METRICS_NAME, pid) }

    static func read(pid: pid_t) -> FGMetricsBlock? {
        let fd = cartouche_shm_open_read(name(pid))
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        let size = Int(FG_METRICS_SIZE)
        guard let map = mmap(nil, size, PROT_READ, MAP_SHARED, fd, 0), map != MAP_FAILED else { return nil }
        defer { munmap(map, size) }
        let block = map.assumingMemoryBound(to: FGMetricsBlock.self)
        for _ in 0..<64 {
            let before = atomicLoad(&block.pointee.sequence)
            guard before & 1 == 0 else { continue }
            let copy = block.pointee
            if atomicLoad(&block.pointee.sequence) == before {
                guard copy.magic == FG_METRICS_MAGIC, copy.version == FG_METRICS_VERSION,
                      copy.size == FG_METRICS_SIZE, copy.pid == pid else { return nil }
                return copy
            }
        }
        return nil
    }

    // nil while the game has not measured a whole second
    static func metrics(_ b: FGMetricsBlock) -> GameMetrics? {
        guard b.seconds > 0 else { return nil }
        var ring = b.frame_ms_ring
        let count = Int(min(b.frame_count, FG_METRICS_FRAMES))
        let times: [Double] = withUnsafeBytes(of: &ring) { raw in
            let all = raw.bindMemory(to: Float.self)
            return (0..<min(count, 120)).map { i in
                Double(all[Int((b.frame_count - UInt32(min(count, 120)) + UInt32(i)) % FG_METRICS_FRAMES)])
            }
        }
        return GameMetrics(
            presentedFPS: Double(b.presented_fps), realFPS: Double(b.real_fps), low1FPS: Double(b.low1_fps),
            frameMs: Double(b.frame_ms), latencyMs: Double(b.added_latency_ms), cpuPercent: Double(b.cpu_percent),
            gpuPercent: b.gpu_percent >= 0 ? Double(b.gpu_percent) : nil, ramBytes: b.ram_bytes, thermal: Int(b.thermal),
            upscale: UpscaleMode(rawValue: Int(b.upscale)) ?? .off,
            upscaleOut: CGSize(width: Int(b.upscale_out_width), height: Int(b.upscale_out_height)),
            frameGenFactor: b.framegen == 1 ? Int(b.framegen_factor) : 1, neuralEngine: b.framegen_ane != 0,
            frameTimes: times)
    }

    private static func atomicLoad(_ p: UnsafeMutablePointer<UInt32>) -> UInt32 {
        OSMemoryBarrier()
        let v = UnsafeMutableRawPointer(p).load(as: UInt32.self)
        OSMemoryBarrier()
        return v
    }
}

// The app's /cartouche-control.<pid>: what the HUD inside the game shows, changed live
struct HUDControl: Equatable, Sendable {
    var level = HUDLevel.standard
    var corner = HUDCorner.topLeft
    var scale = 100
    var menuOpen = false
    var reduceMotion = false
    var battery: Int?
    var gpuWatts: Double?
    var warning = ""
    var hotkey = "⌥C"
    var safeTop = 0.0
    var screenHeight = 0.0
    var language = OverlayText.language
}

final class ControlBlockWriter {
    let pid: pid_t
    private let map: UnsafeMutableRawPointer
    private let name: String

    init?(pid: pid_t) {
        self.pid = pid
        name = String(format: FG_CONTROL_NAME, pid)
        let fd = cartouche_shm_open_write(name)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        guard ftruncate(fd, off_t(FG_CONTROL_SIZE)) == 0,
              let m = mmap(nil, Int(FG_CONTROL_SIZE), PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0), m != MAP_FAILED
        else { return nil }
        map = m
        let block = map.assumingMemoryBound(to: FGControlBlock.self)
        if block.pointee.magic != FG_CONTROL_MAGIC {
            block.pointee.magic = FG_CONTROL_MAGIC
            block.pointee.version = FG_CONTROL_VERSION
            block.pointee.size = FG_CONTROL_SIZE
            block.pointee.pid = pid
            block.pointee.sequence = 0
        }
    }

    func write(_ c: HUDControl) {
        let block = map.assumingMemoryBound(to: FGControlBlock.self)
        let seq = block.pointee.sequence
        block.pointee.sequence = seq | 1
        OSMemoryBarrier()
        block.pointee.hud_level = Int32(c.level.rawValue)
        block.pointee.hud_corner = Int32(c.corner.rawValue)
        block.pointee.hud_scale = Int32(c.scale)
        block.pointee.menu_open = c.menuOpen ? 1 : 0
        block.pointee.reduce_motion = c.reduceMotion ? 1 : 0
        block.pointee.battery_percent = Int32(c.battery ?? -1)
        block.pointee.gpu_watts = Float(c.gpuWatts ?? -1)
        Self.copy(c.warning, into: &block.pointee.warning)
        Self.copy(c.hotkey, into: &block.pointee.hotkey)
        block.pointee.safe_top = Float(c.safeTop)
        block.pointee.screen_height = Float(c.screenHeight)
        Self.copy(c.language, into: &block.pointee.language)
        OSMemoryBarrier()
        block.pointee.sequence = (seq | 1) &+ 1
    }

    func read() -> FGControlBlock { map.assumingMemoryBound(to: FGControlBlock.self).pointee }

    // UTF-8, cut on a character boundary, always terminated
    static func copy<T>(_ text: String, into field: inout T) {
        withUnsafeMutableBytes(of: &field) { raw in
            raw.initializeMemory(as: UInt8.self, repeating: 0)
            var used = 0
            for ch in text {
                let bytes = Array(String(ch).utf8)
                guard used + bytes.count < raw.count else { break }
                for b in bytes { raw[used] = b; used += 1 }
            }
        }
    }

    static func string<T>(_ field: T) -> String {
        withUnsafeBytes(of: field) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    func remove() {
        munmap(map, Int(FG_CONTROL_SIZE))
        shm_unlink(name)
    }
}
