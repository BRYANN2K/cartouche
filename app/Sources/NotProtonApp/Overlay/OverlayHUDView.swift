import SwiftUI

// The HUD drawn by the app, outside the game: the only HUD of a protected game. One glass
// container whose size springs between levels; leaving blocks fade first, new ones after.
struct OverlayHUD: View {
    let level: HUDLevel
    let metrics: GameMetrics?
    let mac: MacReadings
    var protected = false
    var captureAllowed = true
    var upscale = UpscaleMode.off
    var renderScale = 100
    @Environment(\.overlayLook) private var look

    var body: some View {
        Group {
            if level == .mini {
                mini
                    .padding(.horizontal, OS.s4)
                    .frame(height: OS.bar)
                    .fixedSize()
            } else if level != .hidden {
                VStack(alignment: .leading, spacing: 0) {
                    top
                    if metrics != nil && (!protected || captureAllowed) {
                        FrameGraph(times: metrics?.frameTimes ?? [], external: metrics?.external == true)
                            .frame(width: 204, height: 34).padding(.top, 10)
                        standardGrid.padding(.top, 10)
                    }
                    if level == .full || (protected && !captureAllowed) {
                        Rectangle().fill(look.separator).frame(height: 1).padding(.top, 10)
                        macGrid.padding(.top, 10)
                    }
                }
                .padding(.vertical, OS.s3)
                .padding(.horizontal, OS.s4)
                .frame(width: 236, alignment: .leading)
                .transition(.opacity.animation(.easeOut(duration: 0.13).delay(0.11)))
            }
        }
        .overlaySurface(RoundedRectangle(cornerRadius: 22, style: .continuous), large: false)
        .animation(look.reduceMotion ? .easeInOut(duration: 0.12) : .spring(duration: 0.24, bounce: 0), value: level)
        .opacity(level == .hidden ? 0 : 1)
    }

    private var fps: String? { metrics.map { OverlayFormat.whole($0.presentedFPS) } }

    @ViewBuilder
    private var mini: some View {
        HStack(spacing: 12) {
            if metrics == nil && !protected {
                Text(ot("Waiting for the game")).font(.system(size: OS.t1)).foregroundStyle(look.label3)
            } else if protected && !captureAllowed {
                pair(OverlayFormat.whole(mac.cpuPercent ?? 0), "% CPU")
                pair(OverlayFormat.whole(mac.gameGPUPercent ?? mac.gpuPercent ?? 0), "% GPU")
            } else {
                pair(fps ?? "—", "FPS")
                if let f = metrics?.frameGenFactor, f > 1 { Text(verbatim: "×\(f)") }
                pair(metrics.map { OverlayFormat.decimal($0.frameMs) } ?? "—", "ms")
            }
        }
        .font(OS.digits(OS.t2, .semibold))
        .lineLimit(1)
    }

    private func pair(_ value: String, _ unit: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(verbatim: value).contentTransition(.numericText())
            Text(verbatim: unit).font(.system(size: OS.t1)).foregroundStyle(look.label2)
        }
    }

    private var top: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(verbatim: fps ?? "—")
                .font(OS.digits(OS.t5, .semibold))
                .tracking(0.28)
                .foregroundStyle(fps == nil ? look.label3 : .white)
                .contentTransition(.numericText())
                .animation(look.reduceMotion ? nil : .spring(duration: 0.22, bounce: 0), value: fps)
            if metrics == nil && !protected {
                Text(ot("Waiting for the game")).font(.system(size: OS.t1)).foregroundStyle(look.label3)
            } else if protected && !captureAllowed {
                Text(ot("FPS not measured")).font(.system(size: OS.t1)).foregroundStyle(look.label2)
            } else {
                Text(verbatim: "FPS").font(.system(size: OS.t1)).foregroundStyle(look.label2)
            }
            Spacer(minLength: 0)
            if protected {
                pill(ot("Anti-cheat"), muted: true)
            } else if let f = metrics?.frameGenFactor, f > 1 {
                pill("×\(f)", muted: false)
            }
        }
    }

    private func pill(_ text: String, muted: Bool) -> some View {
        Text(verbatim: text)
            .font(.system(size: OS.t1, weight: muted ? .medium : .semibold).monospacedDigit())
            .foregroundStyle(muted ? look.label2 : .white)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(OS.fill2, in: .capsule)
            .fixedSize()
    }

    private var standardGrid: some View {
        let low = metrics.map { OverlayFormat.whole($0.low1FPS) } ?? "—"
        let frame = metrics.map { OverlayFormat.unit(OverlayFormat.decimal($0.frameMs), "ms") } ?? "—"
        if protected {
            let gpu = mac.gameGPUPercent.map(OverlayFormat.whole) ?? "—"
            return grid([(low, ot("Approx. 1% low")), (frame, ot("Per Frame")), (gpu, ot("Percent of game GPU"))])
        }
        let real = metrics?.realFPS.map(OverlayFormat.whole) ?? "—"
        let latency = metrics?.latencyMs.map { OverlayFormat.unit(OverlayFormat.whole($0), "ms") } ?? "—"
        let scale = OverlayFormat.percent(Double(upscale == .off ? 100 : renderScale))
        let kinds = [ot("Native"), ot("Cartouche"), ot("DLSS")]
        let ane = metrics?.neuralEngine == true ? ot("Active") : "—"
        return grid([(real, ot("Real")), (low, ot("1% Low")), (latency, ot("Latency")),
                      (scale, kinds[upscale.rawValue]), (frame, ot("Per Frame")), (ane, "Neural E.")])
    }

    private var macGrid: some View {
        let gpu: Double? = protected ? mac.gameGPUPercent : (metrics?.gpuPercent ?? mac.gpuPercent)
        let cpu = mac.cpuPercent.map(OverlayFormat.percent) ?? "—"
        let watts = mac.gpuWatts.map { OverlayFormat.unit(OverlayFormat.decimal($0), "W") } ?? "—"
        let memory = mac.memoryBytes.map { OverlayFormat.unit(OverlayFormat.decimal(Double($0) / 1e9), ot("GB")) } ?? "—"
        let battery = mac.battery.map { OverlayFormat.percent(Double($0)) } ?? "—"
        return grid([(cpu, "CPU"), (gpu.map(OverlayFormat.percent) ?? "—", protected ? ot("Game GPU") : ot("Mac GPU")),
                     (watts, ot("Power")), (memory, ot("Memory")), (Thermal.name(mac.thermal), ot("Heat")), (battery, ot("Battery"))])
    }

    private func grid(_ cells: [(String, String)]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
            ForEach(0..<(cells.count + 2) / 3, id: \.self) { r in
                GridRow {
                    ForEach(0..<3, id: \.self) { c in
                        let i = r * 3 + c
                        if i < cells.count {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(verbatim: cells[i].0).font(OS.digits(OS.t2)).foregroundStyle(.white).lineLimit(1)
                                Text(verbatim: cells[i].1).font(.system(size: OS.t1)).foregroundStyle(look.label2).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }
    }
}

// The HUD in its corner of the screen, with the « Mac surchargé » capsule under it
struct HUDOverlayCorner: View {
    @Bindable var center: OverlayCenter
    @Environment(\.overlayLook) private var look

    var body: some View {
        let s = center.settings
        let alignment: Alignment = [.topLeading, .topTrailing, .bottomLeading, .bottomTrailing][s.corner.rawValue]
        let top = s.corner == .topLeft || s.corner == .topRight
        VStack(alignment: s.corner == .topLeft || s.corner == .bottomLeft ? .leading : .trailing, spacing: OS.s2) {
            if !top { warning }
            OverlayHUD(level: s.hud, metrics: center.live.metrics, mac: center.live.mac, protected: center.restricted,
                       captureAllowed: center.live.captureAllowed, upscale: s.upscale, renderScale: s.renderScale)
            if top { warning }
        }
        .scaleEffect([1, 1.25, 1.5][s.hudSize], anchor: UnitPoint(x: alignment.horizontal == .leading ? 0 : 1, y: top ? 0 : 1))
        .padding(.horizontal, OS.edge)
        .padding(.top, center.safeArea.barTop)
        .padding(.bottom, OS.edge)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
        .animation(look.reduceMotion ? nil : .spring(duration: 0.24, bounce: 0), value: s.corner)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var warning: some View {
        let control = center.hudControl
        if !control.warning.isEmpty && !center.isOpen && center.settings.hud != .hidden {
            HStack(spacing: 8) {
                Circle().fill(OS.orange).frame(width: 7, height: 7)
                Text(verbatim: control.warning).lineLimit(1)
                KeyCap(text: control.hotkey)
            }
            .font(.system(size: OS.t2))
            .padding(.vertical, OS.s2).padding(.leading, OS.s3).padding(.trailing, OS.s2)
            .frame(maxWidth: 340)
            .overlaySurface(Capsule(), large: false)
        }
    }
}
