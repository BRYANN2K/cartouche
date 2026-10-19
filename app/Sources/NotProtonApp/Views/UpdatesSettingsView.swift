import SwiftUI

// Settings > General hosts this section
struct UpdatesSection: View {

    @AppStorage(UpdateChannel.betaDefaultsKey) private var receiveBetas = false

    var body: some View {
        Section {
            Toggle(isOn: $receiveBetas) {
                Text("Receive beta updates")
                Text("Betas get new features first and may have more bugs. Turning this off keeps the beta until the next release.")
            }
        }
    }
}

struct UpdatesSettingsView: View {

    var body: some View {
        Form {
            UpdatesSection()
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}
