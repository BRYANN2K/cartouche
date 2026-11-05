import SwiftUI

// Pressed controls shrink to .97 on press, never on release
struct OverlayPressStyle: ButtonStyle {
    var scale: CGFloat = 0.97
    @Environment(\.overlayLook) private var look

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !look.reduceMotion ? scale : 1)
            .animation(OverlayMotion.press(look.reduceMotion), value: configuration.isPressed)
    }
}

struct OverlayButton: View {
    let title: String
    var prominent = false
    var danger = false
    var armed = false
    var outlined = false
    var minWidth: CGFloat?
    let action: () -> Void
    @Environment(\.overlayLook) private var look
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: OS.t2, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(foreground)
                .padding(.horizontal, OS.s3)
                .frame(minWidth: minWidth)
                .frame(height: OS.control)
                .background(background, in: .capsule)
                .overlay {
                    if look.contrast { Capsule().strokeBorder(.white.opacity(prominent || armed ? 0.6 : 0.34), lineWidth: 1) }
                    if outlined { Capsule().strokeBorder(OS.accent, lineWidth: 2) }
                }
                .contentShape(.capsule)
        }
        .buttonStyle(OverlayPressStyle())
        .opacity(enabled ? 1 : 0.35)
    }

    private var foreground: Color {
        if prominent || armed { return .white }
        return danger ? OS.danger : .white
    }

    private var background: Color {
        if armed { return OS.red }
        return prominent ? OS.accent : OS.fill2
    }
}

// The mockup's 28 pt capsule segmented control with a pill that springs to the choice
struct OverlaySegments: View {
    let options: [String]
    @Binding var selection: Int
    var dimmed = false
    var focused = false
    @Namespace private var space
    @Environment(\.overlayLook) private var look

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                Button { selection = index } label: {
                    Text(option)
                        .font(.system(size: OS.t2, weight: .medium))
                        .lineLimit(1)
                        .foregroundStyle(index == selection ? (dimmed ? look.label2 : Color.white) : look.label2)
                        .padding(.horizontal, OS.s3)
                        .frame(maxHeight: .infinity)
                        .background {
                            if index == selection && !dimmed {
                                Capsule().fill(OS.fill3)
                                    .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
                                    .overlay {
                                        if focused { Capsule().strokeBorder(OS.accent.opacity(0.9), lineWidth: 2) }
                                        else if look.contrast { Capsule().strokeBorder(.white.opacity(0.8), lineWidth: 1.5) }
                                    }
                                    .matchedGeometryEffect(id: "pill", in: space)
                            }
                        }
                        .contentShape(.capsule)
                }
                .buttonStyle(OverlayPressStyle(scale: 0.96))
                .accessibilityAddTraits(index == selection ? .isSelected : [])
            }
        }
        .padding(2)
        .frame(height: OS.control)
        .background(look.fill, in: .capsule)
        .overlay { if look.contrast { Capsule().strokeBorder(.white.opacity(0.34), lineWidth: 1) } }
        .animation(OverlayMotion.pill(look.reduceMotion), value: selection)
    }
}

struct OverlaySwitch: View {
    @Binding var isOn: Bool
    var dimmed = false
    @Environment(\.overlayLook) private var look
    @GestureState private var pressed = false

    var body: some View {
        let on = isOn && !dimmed
        Capsule()
            .fill(on ? OS.accent : OS.track)
            .frame(width: 38, height: 22)
            .overlay(alignment: on ? .trailing : .leading) {
                Capsule().fill(.white)
                    .shadow(color: .black.opacity(0.35), radius: 1.5, y: 1)
                    .frame(width: pressed && !look.reduceMotion ? 22 : 18, height: 18)
                    .padding(2)
            }
            .overlay { if look.contrast { Capsule().strokeBorder(.white.opacity(on ? 0.6 : 0.34), lineWidth: 1) } }
            .contentShape(.capsule)
            .animation(OverlayMotion.toggle(look.reduceMotion), value: on)
            .animation(OverlayMotion.press(look.reduceMotion), value: pressed)
            .gesture(DragGesture(minimumDistance: 0).updating($pressed) { _, state, _ in state = true }
                .onEnded { _ in isOn.toggle() })
            .accessibilityElement()
            .accessibilityAddTraits(.isToggle)
            .accessibilityValue(isOn ? Text(verbatim: "1") : Text(verbatim: "0"))
            .accessibilityAction { isOn.toggle() }
    }
}

struct OverlaySlider: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int
    let text: String
    var dimmed = false
    @Environment(\.overlayLook) private var look
    @State private var dragging = false

    var body: some View {
        HStack(spacing: OS.s3) {
            GeometryReader { geo in
                let fraction = CGFloat(value - range.lowerBound) / CGFloat(range.upperBound - range.lowerBound)
                ZStack(alignment: .leading) {
                    Capsule().fill(OS.track).frame(height: 4)
                    Capsule().fill(dimmed ? look.label3 : OS.accent).frame(width: geo.size.width * fraction, height: 4)
                    Capsule().fill(.white)
                        .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                        .frame(width: 24, height: 18)
                        .scaleEffect(dragging && !look.reduceMotion ? 1.12 : 1)
                        .offset(x: geo.size.width * fraction - 12)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle().inset(by: -8))
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        dragging = true
                        let p = min(max(0, g.location.x / max(geo.size.width, 1)), 1)
                        let raw = Double(range.lowerBound) + Double(p) * Double(range.upperBound - range.lowerBound)
                        value = min(max(range.lowerBound, Int((raw / Double(step)).rounded()) * step), range.upperBound)
                    }
                    .onEnded { _ in dragging = false })
                .animation(dragging || look.reduceMotion ? nil : .easeOut(duration: 0.16), value: value)
            }
            .frame(width: 170, height: 22)
            Text(text)
                .font(OS.digits(OS.t2, .regular))
                .foregroundStyle(look.label2)
                .frame(minWidth: 60, alignment: .trailing)
        }
        .accessibilityElement()
        .accessibilityValue(Text(verbatim: text))
        .accessibilityAdjustableAction { direction in
            value = min(max(range.lowerBound, value + (direction == .increment ? step : -step)), range.upperBound)
        }
    }
}

// Four small cells for the HUD's corner
struct CornerPicker: View {
    @Binding var selection: Int
    @Environment(\.overlayLook) private var look

    var body: some View {
        Grid(horizontalSpacing: 3, verticalSpacing: 3) {
            GridRow { cell(0); cell(1) }
            GridRow { cell(2); cell(3) }
        }
        .padding(3)
        .background(look.fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func cell(_ i: Int) -> some View {
        Button { selection = i } label: {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(i == selection ? OS.accent : look.fill)
                .frame(width: 26, height: 15)
        }
        .buttonStyle(OverlayPressStyle())
        .animation(.easeOut(duration: 0.15), value: selection)
    }
}

struct SoonPill: View {
    @Environment(\.overlayLook) private var look

    var body: some View {
        Text(ot("Coming Soon"))
            .font(.system(size: OS.t1, weight: .semibold))
            .tracking(0.22)
            .foregroundStyle(look.label2)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(OS.fill2, in: .capsule)
    }
}

struct KeyCap: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: OS.t1, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(OS.fill2, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

// The « au prochain lancement » tag after a label
struct LaterTag: View {
    var body: some View {
        Text(ot("next launch"))
            .font(.system(size: OS.t1, weight: .semibold))
            .foregroundStyle(Color(red: 1, green: 179 / 255, blue: 64 / 255))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(OS.orange.opacity(0.2), in: .capsule)
    }
}
