import SwiftUI

// Settings > Consoles: the standalone emulators found, with their version
// and the consoles each plays
struct StandaloneEmulatorsSection: View {
    let emulators: EmulatorShelf

    var body: some View {
        Section {
            if emulators.hasLooked, emulators.installed.isEmpty {
                Text("None found in Applications.", bundle: .module)
                    .foregroundStyle(.secondary)
            }
            ForEach(emulators.installed) { found in
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: found.title)
                    Text(emulators.consoleNames(of: found))
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
            }
        } header: {
            Text("Other Emulators", bundle: .module)
        } footer: {
            Text("Cartouche finds \(EmulatorCatalog.names) in Applications and starts them with their own settings. It never changes those settings.", bundle: .module)
                .foregroundStyle(.secondary)
        }
    }
}

// Under a console in Settings > Consoles: where its games play, when there is a choice
struct ConsoleEmulatorPicker: View {
    let console: Console
    let emulators: EmulatorShelf

    var body: some View {
        let options = emulators.options(for: console)
        if options.count > 1 || !console.hasCore {
            Picker(selection: Binding(
                get: { emulators.selected(for: console) },
                set: { emulators.choose($0, for: console) }
            )) {
                ForEach(options) { Text(verbatim: $0.title).tag($0.id) }
            } label: {
                Text("\(console.name) plays in", bundle: .module)
            }
            if let missing = emulators.route(for: console).missingText {
                Text(missing).foregroundStyle(.orange).font(.callout)
            }
        }
    }
}
