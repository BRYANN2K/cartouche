
import SwiftUI

struct SetupAssistantSection: View {
    @Environment(OnboardingModel.self) private var onboarding: OnboardingModel?

    var body: some View {
        if let onboarding {
            Section {
                LabeledContent {
                    Button("Run Setup Again") { onboarding.runAgain() }
                } label: {
                    Text("Setup")
                    Text("Steam Play, the free runner, consoles, game folders and privacy, as on the first launch.")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct LibraryFoldersSection: View {
    @Environment(GameFolders.self) private var folders: GameFolders?

    var body: some View {
        if let folders { GameFoldersSection(folders: folders) }
    }
}
