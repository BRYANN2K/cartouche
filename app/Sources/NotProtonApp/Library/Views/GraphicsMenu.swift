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
            Text(verbatim: selected.label)
        }
        .fixedSize()
    }
}
