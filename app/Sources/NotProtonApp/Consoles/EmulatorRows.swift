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
                SetupChoiceMenu(title: options.first(where: { $0.id == center.emulators.selected(for: console) })?.title ?? "—",
                                accessibilityTitle: "Emulator") {
                    ForEach(options) { option in
                        Toggle(isOn: Binding(get: { center.emulators.selected(for: console) == option.id },
                                             set: { if $0 { center.chooseEmulator(option.id, for: console) } })) {
                            Text(verbatim: option.title)
                        }
                    }
                }
            }
            Text("For every \(console.name) game.").font(.system(size: 11)).foregroundStyle(Glass.label2)
        }
        if let installed = route.emulator {
            Text("\(installed.emulator.name) uses its own settings, controls and saves.")
                .font(.system(size: 12)).foregroundStyle(Glass.label2)
        }
    }
}
