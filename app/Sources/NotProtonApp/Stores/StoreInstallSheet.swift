import AppKit
import SwiftUI

struct StoreInstallSheet: View {
    let game: Game
    let model: LibraryModel
    let stores: StoreCenter?
    @State private var choice = GameSetupChoice()
    @State private var destination: URL?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings

    private var setup: GameSetup { model.resolution(for: game, choice: choice).setup }
    private var runners: [Runner] { game.source == .steam ? model.steamRunners : model.installRunners }
    private var folder: URL {
        destination ?? (game.source == .steam ? SupportPaths.Steam.userData :
            model.storeGameFolder(game.source, title: game.name, id: game.id.split(separator: ":").last.map(String.init) ?? game.id)
                ?? stores?.folders.gameFolder(game.source, title: game.name, id: game.id)
                ?? model.installsFolder.appending(path: GameFolder.slug(game.name)))
    }
    private var canInstall: Bool {
        (setup.version == .mac || (setup.runner != nil && setup.backend != nil)) &&
            (game.source == .steam || stores != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(game.name).font(.title2.bold())
            Form {
                if model.hasMacBuild(game) {
                    Picker("Version", selection: Binding(get: { setup.version }, set: { choice.version = $0 })) {
                        ForEach(GameVersion.allCases) { Text($0.label).tag($0) }
                    }
                }
                if setup.version == .windows {
                    if runners.isEmpty {
                        Button("Set Up a Runner…") { SettingsRoute.shared.tab = .compatibility; openSettings() }
                    } else {
                        Picker("Runner", selection: Binding(get: { setup.runner?.id ?? "" }, set: { choice.runnerID = $0 })) {
                            ForEach(runners) { Text(verbatim: "\($0.name) \($0.displayVersion)").tag($0.id) }
                        }
                        if let runner = setup.runner {
                            let backends = BackendSupport.backends(for: runner, translation: setup.translation, availability: model.backendAvailability)
                            Picker("Graphics", selection: Binding(get: { setup.backend ?? .wined3d }, set: { choice.graphics = $0 })) {
                                ForEach(backends) { Text(verbatim: $0.label).tag($0) }
                            }
                            let translations = game.source == .steam ? BackendSupport.translations(for: runner) : [.rosetta]
                            if translations.count > 1 {
                                Picker("Translation", selection: Binding(get: { setup.translation }, set: { choice.translation = $0 })) {
                                    ForEach(translations, id: \.self) { Text(verbatim: $0.label).tag($0) }
                                }
                            }
                        }
                    }
                }
                LabeledContent("Location") {
                    HStack {
                        Text(verbatim: folder.path(percentEncoded: false)).lineLimit(1).truncationMode(.middle)
                        Button("Choose…", action: chooseFolder)
                    }
                }
            }
            .formStyle(.grouped)
            .frame(minHeight: 180)
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Install") {
                    model.setSetup(choice, for: game.id)
                    if game.source == .steam {
                        SteamInstallCenter.shared.install(game, model: model, destination: folder)
                    } else { stores?.install(game, destination: folder) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canInstall)
            }
        }
        .padding(24)
        .frame(width: 560)
        .onAppear { choice = model.setup(for: game.id) }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK { destination = panel.url }
    }
}
