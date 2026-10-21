import SwiftUI

// Geometry from cartouche-site/kit/Pad.astro, in its 0 30 528 300 view box.
struct ControllerShell: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 152, y: 60))
        p.addLine(to: CGPoint(x: 368, y: 60))
        p.addCurve(to: CGPoint(x: 488, y: 156), control1: CGPoint(x: 430, y: 60), control2: CGPoint(x: 468, y: 94))
        p.addLine(to: CGPoint(x: 508, y: 232))
        p.addCurve(to: CGPoint(x: 442, y: 278), control1: CGPoint(x: 518, y: 278), control2: CGPoint(x: 478, y: 304))
        p.addLine(to: CGPoint(x: 388, y: 236))
        p.addLine(to: CGPoint(x: 132, y: 236))
        p.addLine(to: CGPoint(x: 78, y: 278))
        p.addCurve(to: CGPoint(x: 12, y: 232), control1: CGPoint(x: 42, y: 304), control2: CGPoint(x: 2, y: 278))
        p.addLine(to: CGPoint(x: 32, y: 156))
        p.addCurve(to: CGPoint(x: 152, y: 60), control1: CGPoint(x: 52, y: 94), control2: CGPoint(x: 90, y: 60))
        p.closeSubpath()
        return p.applying(CGAffineTransform(translationX: 0, y: -30)
            .concatenating(CGAffineTransform(scaleX: rect.width / 528, y: rect.height / 300)))
    }
}

struct ControllerDiagram: View {
    let family: PadFamily
    var state = PadState.idle
    var highlighted: PadButton?
    var target: (PadButton) -> String = { $0.xbox }

    private struct Part {
        var frame: CGRect
        var radius: CGFloat
    }

    private func part(_ button: PadButton) -> Part {
        switch button {
        case .south: Part(frame: CGRect(x: 378, y: 154, width: 28, height: 28), radius: 14)
        case .east: Part(frame: CGRect(x: 406, y: 126, width: 28, height: 28), radius: 14)
        case .west: Part(frame: CGRect(x: 350, y: 126, width: 28, height: 28), radius: 14)
        case .north: Part(frame: CGRect(x: 378, y: 98, width: 28, height: 28), radius: 14)
        case .leftShoulder: Part(frame: CGRect(x: 104, y: 40, width: 96, height: 26), radius: 12)
        case .rightShoulder: Part(frame: CGRect(x: 320, y: 40, width: 96, height: 26), radius: 12)
        case .leftTrigger: Part(frame: CGRect(x: 112, y: 4, width: 80, height: 29), radius: 9)
        case .rightTrigger: Part(frame: CGRect(x: 328, y: 4, width: 80, height: 29), radius: 9)
        case .leftStick: Part(frame: CGRect(x: 190, y: 198, width: 32, height: 32), radius: 16)
        case .rightStick: Part(frame: CGRect(x: 298, y: 198, width: 32, height: 32), radius: 16)
        case .back: Part(frame: CGRect(x: 224, y: 116, width: 24, height: 14), radius: 7)
        case .start: Part(frame: CGRect(x: 272, y: 116, width: 24, height: 14), radius: 7)
        case .up: Part(frame: CGRect(x: 122, y: 104, width: 22, height: 26), radius: 3)
        case .down: Part(frame: CGRect(x: 122, y: 152, width: 22, height: 26), radius: 3)
        case .left: Part(frame: CGRect(x: 96, y: 130, width: 26, height: 22), radius: 3)
        case .right: Part(frame: CGRect(x: 144, y: 130, width: 26, height: 22), radius: 3)
        }
    }

    private var readout: PadButton? { highlighted ?? PadButton.allCases.first { state.pressed.contains($0) } }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { proxy in
                let scale = proxy.size.width / 528
                ZStack(alignment: .topLeading) {
                    ControllerShell()
                        .fill(.primary.opacity(0.055))
                        .overlay { ControllerShell().stroke(.primary.opacity(0.25), lineWidth: 1.5) }
                        .frame(width: 528 * scale, height: 300 * scale)
                        .offset(y: 30 * scale)
                    ForEach([206.0, 314.0], id: \.self) { x in
                        Circle().stroke(.primary.opacity(0.15), lineWidth: 1)
                            .frame(width: 60 * scale, height: 60 * scale)
                            .position(x: x * scale, y: 214 * scale)
                    }
                    ForEach(PadButton.allCases) { button in
                        let part = part(button)
                        let pressed = state.pressed.contains(button)
                        let stick = button == .leftStick ? state.leftStick : button == .rightStick ? state.rightStick : .zero
                        let moved = abs(stick.x) > 0.15 || abs(stick.y) > 0.15
                        let active = pressed || moved || highlighted == button
                        RoundedRectangle(cornerRadius: part.radius * scale)
                            .fill(active ? Color.accentColor.opacity(pressed ? 0.9 : 0.32) : Color.primary.opacity(0.08))
                            .overlay {
                                RoundedRectangle(cornerRadius: part.radius * scale)
                                    .stroke(active ? Color.accentColor : Color.primary.opacity(0.42), lineWidth: active ? 1.5 : 1)
                            }
                            .overlay {
                                Text(verbatim: button.diagramLabel(family))
                                    .font(.system(size: (button.isTrigger || button == .leftShoulder || button == .rightShoulder ? 13 : 15) * scale, weight: .semibold))
                                    .foregroundStyle(pressed ? Color.white : Color.primary)
                            }
                            .frame(width: part.frame.width * scale, height: part.frame.height * scale)
                            .position(x: (part.frame.midX + stick.x * 8) * scale,
                                      y: (part.frame.midY - stick.y * 8) * scale)
                    }
                }
            }
            .aspectRatio(528.0 / 330.0, contentMode: .fit)
            .accessibilityHidden(true)
            if let readout {
                Text("\(readout.label(family)) sends \(target(readout))")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            } else {
                Text("Press a button or point to a mapping.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Controller diagram"))
    }
}

extension PadButton {
    func diagramLabel(_ family: PadFamily) -> String {
        switch self {
        case .south where family == .playStation: "×"
        case .east where family == .playStation: "○"
        case .west where family == .playStation: "□"
        case .north where family == .playStation: "△"
        case .up: "↑"
        case .down: "↓"
        case .left: "←"
        case .right: "→"
        case .back: family == .playStation ? "−" : "▱"
        case .start: "≡"
        case .leftStick, .rightStick: ""
        default: label(family)
        }
    }
}
