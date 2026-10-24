import SwiftUI

struct UpdatesSection: View {
    var checkForUpdates: () -> Void = {}

    @AppStorage(UpdateChannel.betaDefaultsKey) private var receiveBetas = false
    @AppStorage(DailyChecks.key) private var dailyChecks = true

    var body: some View {
        Section {
            Toggle(isOn: $dailyChecks) {
                Text("Check for updates and compatibility data daily")
                Text("Check for app and compatibility updates once a day.")
            }
            Toggle(isOn: $receiveBetas) {
                Text("Receive beta updates")
                Text("Betas get new features first and may have more bugs. Turning this off keeps the beta until the next release.")
            }
            HStack {
                Text(verbatim: "Cartouche \(AppVersion.bundled)")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Check for Updates…", action: checkForUpdates)
            }
        }
    }
}


