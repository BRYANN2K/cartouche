import RetroArchKit
import SwiftUI

struct EmulatorRows: View {
    let console: Console
    let route: ConsoleRoute
    let center: ConsoleCenter

    var body: some View {
        let options = center.emulators.options(for: console)
        if options.count > 1 || route != .retroArch {
            PanelRow(title: Text("Emulator")) {
                Picker("Emulator", selection: Binding(
                    get: { center.emulators.selected(for: console) },
                    set: { center.chooseEmulator($0, for: console) }
                )) {
                    ForEach(options) { Text(verbatim: $0.title).tag($0.id) }
                }
                .labelsHidden()
                .fixedSize()
            }
            Text("For every \(console.name) game.").font(.system(size: 11)).foregroundStyle(Glass.label2)
        }
        if let installed = route.emulator {
            Text("\(installed.emulator.name) uses its own settings, controls and saves.")
                .font(.system(size: 12)).foregroundStyle(Glass.label2)
        }
    }
}
