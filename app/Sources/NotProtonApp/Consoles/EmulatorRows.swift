import RetroArchKit
import SwiftUI

// The panel's Setup for a console a standalone emulator plays: which emulator
// starts its games, for every game of the console, as in Settings > Consoles
struct EmulatorRows: View {
    let console: Console
    let route: ConsoleRoute
    let center: ConsoleCenter

    var body: some View {
        let options = center.emulators.options(for: console)
        if options.count > 1 || route != .retroArch {
            Picker("Emulator", selection: Binding(
                get: { center.emulators.selected(for: console) },
                set: { center.chooseEmulator($0, for: console) }
            )) {
                ForEach(options) { Text(verbatim: $0.title).tag($0.id) }
            }
            Text("For every \(console.name) game.").font(.caption).foregroundStyle(.secondary)
        }
        if let installed = route.emulator {
            Text("\(installed.emulator.name) uses its own settings, controls and saves.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}
