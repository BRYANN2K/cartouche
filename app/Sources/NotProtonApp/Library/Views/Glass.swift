// Liquid Glass on macOS 26, standard materials on macOS 15, and an opaque fill when
// Reduce Transparency is on. Motion follows Reduce Motion.

import SwiftUI

enum GlassMode: Sendable {
    case liquid
    case classic

    static var system: GlassMode {
        if #available(macOS 26, *) { return .liquid }
        return .classic
    }
}

private struct GlassModeKey: EnvironmentKey {
    static let defaultValue = GlassMode.system
}

extension EnvironmentValues {
    // Snapshots set .classic to render the macOS 15 look on a newer Mac
    var glassMode: GlassMode {
        get { self[GlassModeKey.self] }
        set { self[GlassModeKey.self] = newValue }
    }
}

// What Reduce Motion turns into: tilt off, entrances and sheet springs become fades
enum Motion: Equatable {
    case full
    case reduced

    init(reduceMotion: Bool) { self = reduceMotion ? .reduced : .full }

    var tilts: Bool { self == .full }

    var grid: Animation? { self == .full ? .spring(duration: 0.35, bounce: 0.15) : nil }

    var panel: Animation { self == .full ? .spring(duration: 0.3, bounce: 0.1) : .easeInOut(duration: 0.15) }

    var entrance: AnyTransition {
        self == .full ? .scale(scale: 0.96).combined(with: .opacity) : .opacity
    }
}

private struct GroupBackground: ViewModifier {
    @Environment(\.glassMode) private var mode
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var radius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if reduceTransparency {
            content.background(Color(nsColor: .controlBackgroundColor), in: shape)
        } else if #available(macOS 26, *), mode == .liquid {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
        }
    }
}

private struct ProminentButton: ViewModifier {
    @Environment(\.glassMode) private var mode

    func body(content: Content) -> some View {
        if #available(macOS 26, *), mode == .liquid {
            content.buttonStyle(.glassProminent)
        } else {
            content.buttonStyle(.borderedProminent)
        }
    }
}

private struct PlainGlassButton: ViewModifier {
    @Environment(\.glassMode) private var mode

    func body(content: Content) -> some View {
        if #available(macOS 26, *), mode == .liquid {
            content.buttonStyle(.glass)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

extension View {
    // A grouped block of the panel: glass on 26, material on 15
    func groupBackground(radius: CGFloat = 12) -> some View { modifier(GroupBackground(radius: radius)) }

    func prominentButton() -> some View { modifier(ProminentButton()) }

    func glassButton() -> some View { modifier(PlainGlassButton()) }
}
