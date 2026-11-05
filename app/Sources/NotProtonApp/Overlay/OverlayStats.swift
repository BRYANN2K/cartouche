import SwiftUI

// The five numbers and the frame-time graph at the top of Performance
struct StatsGroup: View {
    @Bindable var center: OverlayCenter
    @Environment(\.overlayLook) private var look

    var body: some View {
        let m = center.live.metrics
        let protected = center.restricted
        OverlayGroup {
            WeightedHStack(weights: [1.25, 1, 1, 1, 1], spacing: 0) {
                cell(m.map { OverlayFormat.whole($0.presentedFPS) }, ot("FPS Shown"), big: true, first: true)
                if protected {
                    cell(m.map { OverlayFormat.whole($0.low1FPS) }, ot("1% Low"), approx: m?.external == true)
                    cell(m.map { OverlayFormat.decimal($0.frameMs) }, ot("ms per Frame"))
                    cell(nil, ot("Real FPS"))
                    cell(nil, ot("ms Latency"))
                } else {
                    cell(m?.realFPS.map(OverlayFormat.whole), ot("Real FPS"))
                    cell(m.map { OverlayFormat.whole($0.low1FPS) }, ot("1% Low"))
                    cell(m.map { OverlayFormat.decimal($0.frameMs) }, ot("ms per Frame"))
                    cell(m?.latencyMs.map(OverlayFormat.whole), ot("ms Latency"))
                }
            }
            .padding(.vertical, OS.s3)
            .padding(.horizontal, OS.s1)
            FrameGraph(times: m?.frameTimes ?? [], external: m?.external == true)
                .frame(height: 56)
                .padding(OS.s3)
        }
    }

    private func cell(_ value: String?, _ label: String, big: Bool = false, first: Bool = false, approx: Bool = false) -> some View {
        HStack(spacing: 0) {
            if !first { Rectangle().fill(look.separator).frame(width: 1) }
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    if approx && value != nil { Text(verbatim: "≈").font(.system(size: big ? 21 : 15)).foregroundStyle(look.label2) }
                    Text(verbatim: value ?? "—")
                        .font(OS.digits(big ? OS.t5 : OS.t4, big ? .semibold : .medium))
                        .tracking(big ? 0.28 : -0.2)
                        .foregroundStyle(value == nil ? look.label3 : .white)
                        .contentTransition(.numericText())
                        .animation(look.reduceMotion ? nil : .spring(duration: 0.22, bounce: 0), value: value)
                        .lineLimit(1)
                }
                Text(label).font(.system(size: OS.t1)).foregroundStyle(look.label2).lineLimit(1)
            }
            .padding(.horizontal, OS.s3)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

// Frame times in ms: three dashed lines at 120, 60 and 30 fps, the curve in green, dashed when measured from outside
struct FrameGraph: View {
    let times: [Double]
    var external = false

    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            func y(_ ms: Double) -> CGFloat { h - 1 - CGFloat(min(ms, 34) / 34) * (h - 2) }
            for ms in [8.3, 16.7, 33.3] {
                var line = Path()
                let at = (y(ms)).rounded() + 0.5
                line.move(to: CGPoint(x: 0, y: at))
                line.addLine(to: CGPoint(x: w, y: at))
                ctx.stroke(line, with: .color(Color(red: 235 / 255, green: 235 / 255, blue: 245 / 255).opacity(0.22)),
                           style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
            }
            guard times.count > 1 else { return }
            var curve = Path()
            for (i, ms) in times.enumerated() {
                let p = CGPoint(x: CGFloat(i) / CGFloat(times.count - 1) * w, y: y(ms))
                if i == 0 { curve.move(to: p) } else { curve.addLine(to: p) }
            }
            var area = curve
            area.addLine(to: CGPoint(x: w, y: h))
            area.addLine(to: CGPoint(x: 0, y: h))
            area.closeSubpath()
            let tone = external ? Color(red: 235 / 255, green: 235 / 255, blue: 245 / 255) : OS.green
            ctx.fill(area, with: .color(tone.opacity(external ? 0.08 : 0.14)))
            ctx.stroke(curve, with: .color(external ? tone.opacity(0.7) : tone),
                       style: StrokeStyle(lineWidth: 1.5, lineJoin: .round, dash: external ? [3, 3] : []))
        }
        .accessibilityHidden(true)
    }
}

// Votre Mac: CPU, GPU, GPU power, memory, heat, Neural Engine
struct MacGroup: View {
    @Bindable var center: OverlayCenter
    @Environment(\.overlayLook) private var look

    var body: some View {
        let mac = center.live.mac
        let m = center.live.metrics
        let protected = center.restricted
        let gpu = protected ? mac.gameGPUPercent : (m?.gpuPercent ?? mac.gpuPercent)
        OverlayGroup {
            HStack(spacing: 0) {
                cell(mac.cpuPercent.map(OverlayFormat.percent), "CPU", hot: (mac.cpuPercent ?? 0) > 85, first: true)
                cell(gpu.map(OverlayFormat.percent), protected ? ot("Game GPU") : ot("Mac GPU"), hot: (gpu ?? 0) > 95)
                cell(mac.gpuWatts.map { OverlayFormat.unit(OverlayFormat.decimal($0), "W") }, ot("GPU Power"))
                cell(Self.memory(mac), ot("Memory"), tint: mac.memoryPressure == .critical ? OS.red : mac.memoryPressure == .warning ? OS.orange : nil)
                cell(Thermal.name(mac.thermal), ot("Heat"), hot: mac.thermal >= 2)
                if !protected {
                    cell(m.map { $0.neuralEngine ? ot("Active") : ot("Inactive") }, "Neural Engine")
                }
            }
            .padding(.vertical, OS.s3)
            .padding(.horizontal, OS.s1)
        }
    }

    // « 17,1 / 24 Go »: used over the Mac's RAM, as the « Apps en arrière-plan » window writes it
    static func memory(_ mac: MacReadings) -> String? {
        guard let used = mac.memoryUsed, let total = mac.memoryTotal, total > 0 else { return nil }
        return OverlayFormat.unit(BackgroundAppsFormat.memory(used: used, physical: total, locale: OverlayText.locale), ot("GB"))
    }

    private func cell(_ value: String?, _ label: String, hot: Bool = false, tint: Color? = nil, first: Bool = false) -> some View {
        HStack(spacing: 0) {
            if !first { Rectangle().fill(look.separator).frame(width: 1) }
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: value ?? "—")
                    .font(OS.digits(OS.t3, value == nil ? .regular : .medium))
                    .foregroundStyle(value == nil ? look.label3 : tint ?? (hot ? OS.orange : .white))
                    .lineLimit(1)
                Text(label).font(.system(size: OS.t1)).foregroundStyle(look.label2).lineLimit(1)
            }
            .padding(.horizontal, OS.s3)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}
