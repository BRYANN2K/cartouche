import Observation
import SwiftUI

// Where Settings opens next; read by the Settings window when it appears
@MainActor
@Observable
final class SettingsRoute {
    static let shared = SettingsRoute()
    var tab: SettingsTab?
}

// Only backends this runner can use, plus a way to get more when something is missing.
struct GraphicsMenu: View {
    let selected: GraphicsBackend
    let offered: [GraphicsBackend]
    var controlWidth: CGFloat? = nil
    let choose: (GraphicsBackend) -> Void

    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Menu {
            ForEach(offered) { backend in
                Toggle(isOn: Binding(get: { backend == selected }, set: { if $0 { choose(backend) } })) {
                    Text(verbatim: backend.label)
                }
            }
            if offered.count < GraphicsBackend.allCases.count {
                if !offered.isEmpty { Divider() }
                Button("Get More Graphics Backends…") {
                    SettingsRoute.shared.tab = .compatibility
                    openSettings()
                }
            }
        } label: {
            SetupMenuLabel(title: selected.label, width: controlWidth)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

struct SetupMenuLabel: View {
    static let controlWidth: CGFloat = 172
    let title: String
    var width: CGFloat? = nil

    var body: some View {
        HStack(spacing: 8) {
            Text(verbatim: title)
                .lineLimit(1)
                .minimumScaleFactor(0.9)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.primary)
        .padding(.horizontal, 10)
        .frame(width: width, height: 30)
        .background(Glass.fill, in: .rect(cornerRadius: 8))
        .contentShape(.rect(cornerRadius: 8))
    }
}

struct SetupChoiceMenu<Choices: View>: View {
    let title: String
    let accessibilityTitle: LocalizedStringKey
    @ViewBuilder var choices: () -> Choices

    var body: some View {
        Menu(content: choices) {
            SetupMenuLabel(title: title, width: SetupMenuLabel.controlWidth)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(Text(accessibilityTitle))
    }
}
