import SwiftUI

struct SupportCartoucheSection: View {
    let destination: URL

    var body: some View {
        Section {
            LabeledContent {
                Link(destination: destination) {
                    Label("Support on Ko-fi", systemImage: "arrow.up.right")
                }
                .buttonStyle(.bordered)
                .fixedSize()
            } label: {
                Text("Support Cartouche")
                Text("If you enjoy Cartouche, you can support its development.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
