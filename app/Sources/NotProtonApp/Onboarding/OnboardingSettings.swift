// Where each onboarding choice lives afterwards, in the Settings window:
// the whole setup again (General), game folders (Library), the free runner
// (Compatibility). Consoles and privacy have their own panes already.

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

struct FreeRunnerSection: View {
    @Environment(OnboardingModel.self) private var onboarding: OnboardingModel?

    var body: some View {
        if let onboarding {
            Section {
                if let build = onboarding.runner {
                    LabeledContent {
                        switch onboarding.runnerPhase {
                        case .installed: Text("Installed").foregroundStyle(.secondary)
                        case .downloading: ProgressView().controlSize(.small)
                        case .failed, .notInstalled, .none:
                            Button("Download") { Task { await onboarding.downloadRunner() } }
                        }
                    } label: {
                        Text(verbatim: build.title)
                        if case .failed(let message) = onboarding.runnerPhase {
                            Text(message).foregroundStyle(.red)
                        } else {
                            Text("Free runner for Windows games").foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text("No free runner is offered for this version of Cartouche.").foregroundStyle(.secondary)
                }
            } header: {
                Text("Free Runner")
            }
            .onAppear { onboarding.prepareRunner() }
        }
    }
}
