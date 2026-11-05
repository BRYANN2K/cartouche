import SwiftUI

// The mockup's tokens: sizes 4/8/12/16/24/32, text 11/13/15/20/28, radii 26/18/10
enum OS {
    static let s1: CGFloat = 4, s2: CGFloat = 8, s3: CGFloat = 12, s4: CGFloat = 16, s5: CGFloat = 24, s6: CGFloat = 32
    static let t1: CGFloat = 11, t2: CGFloat = 13, t3: CGFloat = 15, t4: CGFloat = 20, t5: CGFloat = 28
    static let bar: CGFloat = 44, control: CGFloat = 28, top: CGFloat = 16, edge: CGFloat = 24, slot: CGFloat = 276
    static let window = Glass.windowRadius, group = Glass.panelRadius, row = Glass.rowRadius

    static let accent = Glass.accentFill
    static let focus = Color(red: 1, green: 77 / 255, blue: 94 / 255).opacity(0.85)
    static let green = Color(red: 48 / 255, green: 209 / 255, blue: 88 / 255)
    static let orange = Color(red: 1, green: 159 / 255, blue: 10 / 255)
    static let red = Color(red: 1, green: 69 / 255, blue: 58 / 255)
    static let danger = Color(red: 1, green: 123 / 255, blue: 114 / 255)
    static let undo = Color(red: 1, green: 77 / 255, blue: 94 / 255)
    static let opaque = Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255)
    static let tint = Color(red: 22 / 255, green: 22 / 255, blue: 26 / 255)
    static let track = Color(red: 120 / 255, green: 120 / 255, blue: 128 / 255).opacity(0.36)

    static func label2(_ contrast: Bool) -> Color { Color(red: 235 / 255, green: 235 / 255, blue: 245 / 255).opacity(contrast ? 0.92 : 0.84) }
    static func label3(_ contrast: Bool) -> Color { Color(red: 235 / 255, green: 235 / 255, blue: 245 / 255).opacity(contrast ? 0.74 : 0.62) }
    static func fill(_ contrast: Bool) -> Color { .white.opacity(contrast ? 0.12 : 0.08) }
    static let fill2 = Color.white.opacity(0.14)
    static let fill3 = Color.white.opacity(0.22)
    static func separator(_ contrast: Bool) -> Color { .white.opacity(contrast ? 0.28 : 0.1) }

    static func digits(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight).monospacedDigit()
    }
}

// Accessibility and material choices the whole overlay reads once
struct OverlayLook: Equatable {
    var reduceTransparency = false
    var contrast = false
    var reduceMotion = false
    var liquid = true

    var label2: Color { OS.label2(contrast) }
    var label3: Color { OS.label3(contrast) }
    var fill: Color { OS.fill(contrast) }
    var separator: Color { OS.separator(contrast) }
}

private struct OverlayLookKey: EnvironmentKey {
    static let defaultValue = OverlayLook()
}

extension EnvironmentValues {
    var overlayLook: OverlayLook {
        get { self[OverlayLookKey.self] }
        set { self[OverlayLookKey.self] = newValue }
    }
}

// The springs of audit-fable C.2; Reduce Motion turns every one into a short fade
@MainActor
enum OverlayMotion {
    static func open(_ reduce: Bool) -> Animation { reduce ? .easeInOut(duration: 0.12) : .spring(duration: 0.26, bounce: 0) }
    static func close(_ reduce: Bool) -> Animation { reduce ? .easeInOut(duration: 0.09) : .spring(duration: 0.16, bounce: 0) }
    static func pill(_ reduce: Bool) -> Animation? { reduce ? nil : .spring(duration: 0.28, bounce: 0.08) }
    static func ring(_ reduce: Bool) -> Animation? { reduce ? nil : .spring(duration: 0.26, bounce: 0.05) }
    static func toggle(_ reduce: Bool) -> Animation { reduce ? .easeInOut(duration: 0.12) : .spring(duration: 0.24, bounce: 0.2) }
    static func press(_ reduce: Bool) -> Animation { reduce ? .linear(duration: 0) : .spring(duration: 0.12, bounce: 0) }
    static func height(_ reduce: Bool) -> Animation? { reduce ? nil : .spring(duration: 0.24, bounce: 0) }
    static let stagger = 0.04

    // Tab content: an 8 pt slide in the tab order by pointer, nothing by keyboard or controller
    static func contentOffset(slide: Int, input: OverlayInput, reduce: Bool) -> CGFloat {
        guard !reduce, input == .pointer else { return 0 }
        return CGFloat(slide) * 8
    }

    static func content(slide: Int, input: OverlayInput, reduce: Bool) -> AnyTransition {
        if input != .pointer { return .identity }
        if reduce { return .opacity.animation(.easeInOut(duration: 0.12)) }
        return .asymmetric(insertion: .offset(x: CGFloat(slide) * 8).combined(with: .opacity).combined(with: AnyTransition(.blurReplace)),
                           removal: .opacity)
    }
}

// A floating surface over the game: Liquid Glass, a material on macOS 15, opaque with Reduce Transparency
struct OverlaySurface<S: InsettableShape>: ViewModifier {
    var shape: S
    var large = true
    @Environment(\.overlayLook) private var look

    func body(content: Content) -> some View {
        Group {
            if look.reduceTransparency {
                content.background(OS.opaque, in: shape)
            } else if look.contrast {
                content.background(Color(red: 18 / 255, green: 18 / 255, blue: 20 / 255).opacity(0.94), in: shape)
            } else if #available(macOS 26, *), look.liquid {
                // The mockup's glass is denser than .regular: a dark layer inside keeps 6:1 on a bright sky
                content.background(OS.tint.opacity(0.5), in: shape).glassEffect(.regular, in: shape)
            } else {
                content.background(OS.tint.opacity(0.62), in: shape).background(.ultraThinMaterial, in: shape)
            }
        }
        .overlay {
            if look.contrast {
                shape.strokeBorder(.white.opacity(0.4), lineWidth: 1)
            } else if !look.reduceTransparency {
                shape.strokeBorder(.white.opacity(0.1), lineWidth: 0.5)
            }
        }
        .compositingGroup()
        .shadow(color: .black.opacity(large ? 0.34 : 0.24), radius: large ? 24 : 9, y: large ? 18 : 6)
    }
}

extension View {
    func overlaySurface<S: InsettableShape>(_ shape: S, large: Bool = true) -> some View {
        modifier(OverlaySurface(shape: shape, large: large))
    }
}
