import Observation
import SwiftUI

// Where Settings opens next; read by the Settings window when it appears
@MainActor
@Observable
final class SettingsRoute {
    static let shared = SettingsRoute()
    var tab: SettingsTab?
}

// Why a backend is missing from a game's choices; the choices themselves still come from BackendSupport
enum BackendReason {
    static func missing(_ backend: GraphicsBackend, runner: Runner?, availability: BackendAvailability) -> String {
        switch backend {
        case .d3dmetal:
            return String(localized: "Needs Game Porting Toolkit")
        case .dxmt:
            if let runner, runner.kind == .wineBuild, !availability.crossOverWine.contains(runner.id) {
                return String(localized: "Needs CrossOver Wine")
            }
            return availability.installed.contains(.dxmt) || runner?.kind == .crossOver
                ? String(localized: "Needs CrossOver Wine") : String(localized: "Download in Settings")
        case .dxvk:
            return String(localized: "Download in Settings")
        case .wined3d:
            return String(localized: "Not with this runner")
        }
    }
}

// Every backend, the ones this game cannot use disabled with the reason, and a way to get more
struct GraphicsMenu: View {
    let selected: GraphicsBackend
    let offered: [GraphicsBackend]
    let runner: Runner?
    let availability: BackendAvailability
    let choose: (GraphicsBackend) -> Void

    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Menu {
            ForEach(BackendSupport.preference, id: \.self) { backend in
                if offered.contains(backend) {
                    Toggle(isOn: Binding(get: { backend == selected }, set: { if $0 { choose(backend) } })) {
                        Text(verbatim: backend.label)
                    }
                } else {
                    Button {} label: {
                        Text(verbatim: backend.label)
                        Text(BackendReason.missing(backend, runner: runner, availability: availability))
                    }
                    .disabled(true)
                }
            }
            Divider()
            Button("Get More Graphics Backends…") {
                SettingsRoute.shared.tab = .compatibility
                openSettings()
            }
        } label: {
            Text(verbatim: selected.label)
        }
        .fixedSize()
    }
}
