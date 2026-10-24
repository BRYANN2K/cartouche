import SwiftUI

struct CommunitySection: View {
    var body: some View {
        Section {
            LabeledContent {
                Link("Join Discord", destination: URL(string: "https://discord.gg/fKxanZyFea")!)
                    .buttonStyle(.bordered)
                    .fixedSize()
            } label: {
                Text("Discord")
                Text("Get help and share feedback.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
