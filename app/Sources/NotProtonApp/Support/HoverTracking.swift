import SwiftUI

private struct HoverEnabledKey: EnvironmentKey { static let defaultValue = true }

extension EnvironmentValues {
    // Off in snapshot tests: SwiftUI follows the real pointer even in a window that ignores mouse events
    var hoverEnabled: Bool {
        get { self[HoverEnabledKey.self] }
        set { self[HoverEnabledKey.self] = newValue }
    }
}

private struct HoverTracking: ViewModifier {
    @Environment(\.hoverEnabled) private var enabled
    let action: (Bool) -> Void

    func body(content: Content) -> some View {
        content.onHover { action(enabled && $0) }
    }
}

extension View {
    func trackHover(_ action: @escaping (Bool) -> Void) -> some View {
        modifier(HoverTracking(action: action))
    }
}
