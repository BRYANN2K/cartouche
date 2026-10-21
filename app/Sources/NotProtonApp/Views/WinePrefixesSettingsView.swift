import SwiftUI

struct WinePrefixesSettingsView: View {
    @Environment(PrefixesModel.self) private var model
    @State private var showsBackups = false

    var body: some View {
        VStack(spacing: 0) {
            Picker("Wine Prefixes", selection: $showsBackups) {
                Text("Prefixes").tag(false)
                Text("Prefix Backups").tag(true)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .padding(20)
            if showsBackups {
                BackupsView()
            } else {
                PrefixesView()
            }
        }
        .onChange(of: showsBackups) { model.forgetOutcome() }
    }
}
