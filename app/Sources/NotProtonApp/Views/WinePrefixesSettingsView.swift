import SwiftUI

struct WinePrefixesSettingsView: View {
    @Environment(PrefixesModel.self) private var model
    @State private var showsBackups = false

    var body: some View {
        VStack(spacing: 0) {
            Picker("Show", selection: $showsBackups) {
                Text("Games").tag(false)
                Text("Backups").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(20)
            if showsBackups {
                BackupsView()
            } else {
                PrefixesView()
            }
        }
        .navigationTitle("Wine Prefixes")
        .onChange(of: showsBackups) { model.forgetOutcome() }
    }
}
