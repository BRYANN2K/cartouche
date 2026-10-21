import SwiftUI

struct SetupDefaultsSection: View {
    let model: LibraryModel
    @State private var defaults = SetupDefaults()
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        // The install runners, CrossOver Wine first: the default also serves installers and store games.
        let runners = model.installRunners
        let backends = model.graphicsChoices(for: defaults)
        Section {
            Picker("Default runner", selection: Binding(
                get: { defaults.runnerID ?? "" },
                set: { defaults.runnerID = $0.isEmpty ? nil : $0; save() }
            )) {
                Text("First Available").tag("")
                ForEach(runners) { Text(verbatim: "\($0.kind.name) \($0.displayVersion)").tag($0.id) }
            }
            LabeledContent("Default graphics") {
                Menu {
                    Picker("Default graphics", selection: Binding(
                        get: { defaults.graphics.flatMap { backends.contains($0) ? $0 : nil } },
                        set: { defaults.graphics = $0; save() }
                    )) {
                        Text("First Available").tag(GraphicsBackend?.none)
                        ForEach(backends) { Text(verbatim: $0.label).tag(Optional($0)) }
                    }
                    .pickerStyle(.inline)
                    if backends.count < GraphicsBackend.allCases.count {
                        Divider()
                        Button("Get More Graphics Backends…") {
                            SettingsRoute.shared.tab = .compatibility
                            openSettings()
                        }
                    }
                } label: {
                    if let backend = defaults.graphics, backends.contains(backend) {
                        Text(verbatim: backend.label)
                    } else {
                        Text("First Available")
                    }
                }
                .fixedSize()
            }
            // FEX runs only on macOS 26, so macOS 15 shows no choice
            if CompatTool.Flavor.fexAvailable {
                Picker("Translation", selection: Binding(
                    get: { defaults.translation ?? .rosetta },
                    set: { defaults.translation = $0; save() }
                )) {
                    ForEach(GameSetupChoice.Translation.allCases, id: \.self) { Text(verbatim: $0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }
        } header: {
            Text("New Games")
        } footer: {
            Text("A game uses these until you pick its own setup. A backend its runner cannot use is replaced by the first one it can.")
        }
        .onAppear { defaults = model.setupDefaults }
    }

    private func save() {
        defaults.save(model.defaults)
        model.tellSteamDefaults()
    }
}

// DXMT and DXVK for Wine builds; CrossOver brings its own copies
struct BackendDownloadsSection: View {
    static let manifest = BackendManifest.current()
    let manifest = Self.manifest
    var folder: URL = BackendInstaller.folder
    var model: LibraryModel?
    @State private var installed: [GraphicsBackend: BackendInstaller.Receipt] = [:]
    @State private var busy: Set<GraphicsBackend> = []
    @State private var message: String?

    var body: some View {
        Section {
            ForEach(manifest.backends) { pin in
                LabeledContent {
                    if busy.contains(pin.backend) {
                        ProgressView().controlSize(.small)
                    } else if installed[pin.backend]?.version == pin.version {
                        Text("Ready").foregroundStyle(.secondary)
                    } else {
                        Button("Download") { download(pin) }
                    }
                } label: {
                    Text(verbatim: pin.title)
                    Text("\(pin.license) license, from \(pin.url.host() ?? "")").foregroundStyle(.secondary)
                }
            }
            if let message { Text(message).foregroundStyle(.red) }
        } header: {
            Text("Graphics Backends")
        } footer: {
            Text("Wine builds use these. CrossOver comes with its own. Each download is checked against its SHA-256 before use.")
        }
        .task { refresh() }
    }

    private func refresh() {
        installed = Dictionary(BackendInstaller.installed(in: folder).map { ($0.backend, $0) }, uniquingKeysWith: { a, _ in a })
        model?.backendAvailability.installed = Set(installed.keys)
    }

    private func download(_ pin: BackendManifest.Pin) {
        busy.insert(pin.backend)
        message = nil
        Task {
            do {
                try await BackendInstaller.install(pin, backends: folder)
            } catch {
                message = (error as? StepFailure)?.detail ?? error.localizedDescription
            }
            busy.remove(pin.backend)
            refresh()
        }
    }
}
