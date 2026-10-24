// Liquid Glass on macOS 26, standard materials on macOS 15, and an opaque fill when Reduce Transparency is on. Motion follows Reduce Motion.

import AppKit
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

// The mockup's tokens: radii, the window and panel fills, and the two neutral fills
enum Glass {
    static let windowRadius: CGFloat = 26
    static let panelRadius: CGFloat = 18
    static let rowRadius: CGFloat = 10
    static let inset: CGFloat = 8
    static let sidebarWidth: CGFloat = 214
    static let panelWidth: CGFloat = 356
    static let toolbarHeight: CGFloat = 60

    static let window = Color(light: .init(srgbRed: 0.953, green: 0.953, blue: 0.965, alpha: 1),
                              dark: .init(srgbRed: 0.086, green: 0.086, blue: 0.094, alpha: 1))
    static let fill = Color(light: .init(white: 0, alpha: 0.05), dark: .init(white: 1, alpha: 0.08))
    static let fill2 = Color(light: .init(white: 0, alpha: 0.09), dark: .init(white: 1, alpha: 0.14))
    static let separator = Color(light: .init(white: 0, alpha: 0.08), dark: .init(white: 1, alpha: 0.09))
    static let label2 = Color(nsColor: .secondaryLabelColor)
    static let label3 = Color(nsColor: .tertiaryLabelColor)
    static let edge = Color(light: .init(white: 0, alpha: 0.08), dark: .init(white: 1, alpha: 0.12))
}

extension Color {
    init(light: NSColor, dark: NSColor) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

// A floating glass surface: the sidebar, the game panel, sheets' cards
private struct FloatingPanel: ViewModifier {
    @Environment(\.glassMode) private var mode
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    var radius: CGFloat
    var liquid: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        Group {
            if reduceTransparency || contrast == .increased {
                content.background(Glass.window, in: shape)
                    .overlay { shape.strokeBorder(contrast == .increased ? Glass.label3 : Glass.edge, lineWidth: contrast == .increased ? 1 : 0.5) }
            } else if #available(macOS 26, *), mode == .liquid, liquid {
                content.glassEffect(.regular, in: shape)
            } else {
                content
                    .background(.regularMaterial, in: shape)
                    .overlay { shape.strokeBorder(Glass.edge, lineWidth: 0.5) }
            }
        }
        .clipShape(shape)
        .shadow(color: .black.opacity(0.10), radius: 8, y: 3)
    }
}

// A grouped card inside a glass surface: a flat translucent fill, never glass on glass
private struct GroupBackground: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var radius: CGFloat
    var tint: Color?

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if let tint {
            content.background(tint.opacity(0.14), in: shape)
        } else if reduceTransparency {
            content.background(Color(nsColor: .controlBackgroundColor), in: shape)
        } else {
            content.background(Glass.fill, in: shape)
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

// The toolbar's search field: a glass capsule on macOS 26, a material one earlier
private struct CapsuleField: ViewModifier {
    @Environment(\.glassMode) private var mode
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(Color(nsColor: .controlBackgroundColor), in: .capsule)
                .overlay { Capsule().strokeBorder(Glass.edge, lineWidth: 0.5) }
        } else if #available(macOS 26, *), mode == .liquid {
            content.glassEffect(.regular, in: .capsule)
        } else {
            content
                .background(.regularMaterial, in: .capsule)
                .overlay { Capsule().strokeBorder(Glass.edge, lineWidth: 0.5) }
        }
    }
}

// The mockup's small pill buttons inside cards: Details, Compare, Customize
struct PillButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 3)
            .background(prominent ? Color.accentColor : Glass.fill2, in: .capsule)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .contentShape(.capsule)
    }
}

// Round actions share the system glass interaction.
struct RoundGlassStyle: ButtonStyle {
    var size: CGFloat = 34

    func makeBody(configuration: Configuration) -> some View {
        RoundGlassBody(label: configuration.label, pressed: configuration.isPressed, size: size)
    }
}

private struct RoundGlassBody<Label: View>: View {
    let label: Label
    let pressed: Bool
    let size: CGFloat

    @Environment(\.glassMode) private var mode
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityShowBorders) private var showBorders
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let core = label
            .foregroundStyle(Color.primary)
            .frame(width: size, height: size)
            .contentShape(.circle)
        Group {
            if reduceTransparency || contrast == .increased {
                core.background(Color(nsColor: .controlBackgroundColor), in: .circle)
                    .overlay { Circle().strokeBorder(Glass.edge, lineWidth: 1) }
            } else if #available(macOS 26, *), mode == .liquid {
                core.glassEffect(.regular.interactive(isEnabled), in: .circle)
            } else {
                core.background(.regularMaterial, in: .circle)
                    .scaleEffect(pressed && !reduceMotion ? 0.96 : 1)
            }
        }
        .overlay { if showBorders { Circle().strokeBorder(Color.primary, lineWidth: 1) } }
        .opacity(isEnabled ? 1 : 0.45)
    }
}

// The panel's primary action keeps a solid fallback for accessibility and older systems.
struct PlayCapsuleStyle: ButtonStyle {
    var tint: Color = .accentColor

    func makeBody(configuration: Configuration) -> some View {
        PlayCapsuleBody(label: configuration.label, pressed: configuration.isPressed, tint: tint)
    }
}

private struct PlayCapsuleBody<Label: View>: View {
    let label: Label
    let pressed: Bool
    let tint: Color

    @Environment(\.glassMode) private var mode
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityShowBorders) private var showBorders
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let core = label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 38)
            .contentShape(.capsule)
        Group {
            if #available(macOS 26, *), mode == .liquid, !reduceTransparency, contrast != .increased {
                core.glassEffect(.regular.tint(tint).interactive(isEnabled), in: .capsule)
            } else {
                core.background(tint, in: .capsule)
                    .brightness(pressed ? -0.08 : 0)
            }
        }
        .overlay { if showBorders { Capsule().strokeBorder(Color.primary, lineWidth: 1) } }
        .opacity(isEnabled ? 1 : 0.45)
    }
}

// A round neutral button on a panel: the "…" next to Play
struct RoundFillStyle: ButtonStyle {
    var size: CGFloat = 38

    func makeBody(configuration: Configuration) -> some View {
        RoundGlassBody(label: configuration.label.font(.system(size: 14, weight: .semibold)),
                       pressed: configuration.isPressed, size: size)
    }
}

// A small label over a large number, as in the panel's Your Play and Expected cards
struct StatCell: View {
    let title: Text
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            title.font(.system(size: 11)).foregroundStyle(Glass.label2)
            Text(verbatim: value)
                .font(.system(size: 17, weight: .bold))
                .tracking(-0.17)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// The mockup's sheet footer buttons: 30 pt capsules, neutral or accent
struct SheetButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        SheetButtonBody(label: configuration.label, pressed: configuration.isPressed, prominent: prominent)
    }
}

private struct SheetButtonBody<Label: View>: View {
    let label: Label
    let pressed: Bool
    let prominent: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .padding(.horizontal, 16)
            .frame(minHeight: 30)
            .background(prominent ? Color.accentColor : Glass.fill2, in: .capsule)
            .contentShape(.capsule)
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(pressed ? 0.96 : 1)
            .animation(.spring(duration: 0.2, bounce: 0), value: pressed)
    }
}

extension ButtonStyle where Self == SheetButtonStyle {
    static var sheet: SheetButtonStyle { SheetButtonStyle() }
    static var sheetProminent: SheetButtonStyle { SheetButtonStyle(prominent: true) }
}

// A sheet's title and the line under it: 17 pt bold over secondary text
struct SheetHeader: View {
    let title: Text
    var message: Text?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            title.font(.system(size: 17, weight: .bold)).tracking(-0.17)
                .accessibilityAddTraits(.isHeader)
            if let message {
                message.font(.system(size: 13)).foregroundStyle(Glass.label2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// Use one continuous fade; the macOS 27 toolbar backdrop otherwise adds a hard edge.
private struct SoftScrollEdges: ViewModifier {
    var top: CGFloat
    var bottom: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content
                .modifier(ClassicScrollEdges(top: top, bottom: bottom))
                .scrollEdgeEffectHidden(true, for: [.top, .bottom])
        } else {
            content.modifier(ClassicScrollEdges(top: top, bottom: bottom))
        }
    }
}

private struct ClassicScrollEdges: ViewModifier {
    var top: CGFloat
    var bottom: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var under = Under()

    struct Under: Equatable {
        var top = false
        var bottom = false
    }

    func body(content: Content) -> some View {
        content
            .scrollBounceBehavior(.basedOnSize, axes: [.vertical, .horizontal])
            .onScrollGeometryChange(for: Under.self) { geometry in
                let offset = geometry.contentOffset.y + geometry.contentInsets.top
                let end = geometry.contentSize.height + geometry.contentInsets.top + geometry.contentInsets.bottom
                return Under(top: offset > 1, bottom: offset + geometry.containerSize.height < end - 1)
            } action: { _, new in
                under = new
            }
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(colors: [under.top ? .clear : .black, .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: top)
                    Color.black
                    LinearGradient(colors: [.black, under.bottom ? .clear : .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: bottom)
                }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: under)
            }
    }
}

extension View {
    // Apply to a ScrollView: its content fades out where it passes under the top or bottom edge
    func softScrollEdges(top: CGFloat = 20, bottom: CGFloat = 20) -> some View {
        modifier(SoftScrollEdges(top: top, bottom: bottom))
    }
}

extension ButtonStyle where Self == PillButtonStyle {
    static var pill: PillButtonStyle { PillButtonStyle() }
    static var pillProminent: PillButtonStyle { PillButtonStyle(prominent: true) }
}

extension View {
    func floatingPanel(radius: CGFloat = Glass.panelRadius, liquid: Bool = true) -> some View {
        modifier(FloatingPanel(radius: radius, liquid: liquid))
    }

    func groupBackground(radius: CGFloat = 12, tint: Color? = nil) -> some View {
        modifier(GroupBackground(radius: radius, tint: tint))
    }

    func prominentButton() -> some View { modifier(ProminentButton()) }

    func capsuleField() -> some View { modifier(CapsuleField()) }

    // The mockup's group header above a card: 11 pt semibold, secondary
    func groupHeader() -> some View {
        font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Glass.label2)
            .padding(.horizontal, 10)
            .accessibilityAddTraits(.isHeader)
    }
}

// An HStack whose columns share the width by weight, like the mockup's 1.3fr 1fr 1fr
struct WeightedHStack: Layout {
    var weights: [CGFloat]
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 300
        let widths = columns(width, subviews.count)
        let height = subviews.indices.map { subviews[$0].sizeThatFits(.init(width: widths[$0], height: nil)).height }.max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let widths = columns(bounds.width, subviews.count)
        var x = bounds.minX
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: x, y: bounds.minY), proposal: .init(width: widths[index], height: bounds.height))
            x += widths[index] + spacing
        }
    }

    private func columns(_ width: CGFloat, _ count: Int) -> [CGFloat] {
        let w = (0..<count).map { $0 < weights.count ? weights[$0] : 1 }
        let free = max(0, width - spacing * CGFloat(max(count - 1, 0)))
        let total = w.reduce(0, +)
        return w.map { free * $0 / max(total, 1) }
    }
}

// The mockup's dashed drop area: an accent icon, a bold line, "or", and a Choose pill
struct DropZone: View {
    let title: Text
    let choose: Text
    var targeted = false
    let action: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        VStack(spacing: 6) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Color.accentColor)
                .padding(.bottom, 4)
                .accessibilityHidden(true)
            title.font(.system(size: 14, weight: .semibold))
            Text("or").font(.system(size: 13)).foregroundStyle(Glass.label2)
            Button(action: action) { choose }
                .buttonStyle(.pill)
                .padding(.top, 2)
        }
        .padding(.vertical, 30)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity)
        .background(targeted ? Color.accentColor.opacity(0.1) : .clear, in: shape)
        .overlay {
            shape.strokeBorder(targeted ? Color.accentColor : Glass.label3, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
        }
        .scaleEffect(targeted ? 1.01 : 1)
        .animation(.spring(duration: 0.3, bounce: 0), value: targeted)
    }
}

// The mockup's .big-cta: a 40 pt accent capsule for a page's one main action
struct BigCapsuleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        BigCapsuleBody(label: configuration.label, pressed: configuration.isPressed)
    }
}

private struct BigCapsuleBody<Label: View>: View {
    let label: Label
    let pressed: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 22)
            .frame(height: 40)
            .background(Color.accentColor.opacity(0.88), in: .capsule)
            .overlay {
                Capsule().strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.3), .white.opacity(0)], startPoint: .top, endPoint: .center),
                    lineWidth: 1)
            }
            .shadow(color: Color.accentColor.opacity(0.35), radius: 9, y: 6)
            .contentShape(.capsule)
            .opacity(isEnabled ? 1 : 0.75)
            .scaleEffect(pressed ? 0.97 : 1)
            .animation(.spring(duration: 0.2, bounce: 0), value: pressed)
    }
}

// A card row as the mockup's .row: a fixed label column, so controls never shift when a value changes,
// and the control up to the trailing edge; a control too wide for that goes under its label
struct PanelRow<Control: View>: View {
    let title: Text
    var labelWidth: CGFloat = 60
    @ViewBuilder let control: () -> Control

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                label.frame(width: labelWidth, alignment: .leading)
                control()
                    .fixedSize()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .frame(minHeight: 30)
            VStack(alignment: .leading, spacing: 6) {
                label
                control()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 2)
        }
    }

    private var label: some View {
        title.font(.system(size: 13)).lineLimit(1)
    }
}

// A switch row: the label takes the room it needs, the switch sits at the trailing edge
struct PanelSwitchRow: View {
    let title: Text
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) { title.font(.system(size: 13)) }
            .toggleStyle(PanelSwitchStyle())
            .frame(minHeight: 30)
    }
}

private struct PanelSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 10) {
            configuration.label
            Spacer(minLength: 8)
            Toggle(isOn: configuration.$isOn) { configuration.label }
                .toggleStyle(.switch)
                .labelsHidden()
        }
    }
}
