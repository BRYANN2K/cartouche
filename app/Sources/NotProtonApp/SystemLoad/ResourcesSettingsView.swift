import SwiftUI

struct ResourcesSettingsView: View {
    @Bindable var monitor: ResourceMonitor
    @State private var newEntry = ""

    var body: some View {
        Form {
            Section {
                Toggle("Warn when the Mac is too busy for a game", isOn: $monitor.thresholds.enabled)
                LabeledContent(ot("Alert Threshold")) {
                    Text(verbatim: OverlayFormat.percent(monitor.thresholds.otherCPU) + " CPU").monospacedDigit()
                }
                .disabled(!monitor.thresholds.enabled)
            } header: {
                Text("Busy Mac Warning")
            }
            Section {
                ForEach(monitor.userProtected, id: \.self) { entry in
                    LabeledContent(entry) {
                        Button("Remove") { monitor.userProtected.removeAll { $0 == entry } }
                    }
                }
                HStack {
                    TextField("App name or bundle ID", text: $newEntry)
                        .onSubmit(add)
                    Button("Add", action: add)
                        .disabled(newEntry.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Protected Apps")
            }
            Section {
                Button("Open Resources") { monitor.showWindow() }
            }
        }
        .formStyle(.grouped)
    }

    private func add() {
        let entry = newEntry.trimmingCharacters(in: .whitespaces)
        guard !entry.isEmpty else { return }
        if !monitor.userProtected.contains(where: { $0.caseInsensitiveCompare(entry) == .orderedSame }) {
            monitor.userProtected.append(entry)
        }
        newEntry = ""
    }
}
