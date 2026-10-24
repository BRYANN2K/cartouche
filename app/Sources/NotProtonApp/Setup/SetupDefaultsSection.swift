import SwiftUI

struct SetupDefaultsSection: View {
    let model: LibraryModel
    @State private var defaults = SetupDefaults()
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        // The install runners, Cartouche Wine first: the default also serves installers and store games.
        let runners = model.installRunners
        let backends = model.graphicsChoices(for: defaults)
        Section {
            Picker("Default runner", selection: Binding(
                get: { defaults.runnerID ?? "" },
                set: { defaults.runnerID = $0.isEmpty ? nil : $0; save() }
            )) {
                Text("First Available").tag("")
                ForEach(runners) { Text(verbatim: "\($0.name) \($0.displayVersion)").tag($0.id) }
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
    var folder: URL = BackendInstaller.folder
    var model: LibraryModel?
    // Rewrites Steam's backend tool list after a download
    var syncTools: @Sendable () throws -> Void = { _ = try CompatToolList.sync() }
    @State private var manifest = BackendManifest.current()
    @State private var installed: [GraphicsBackend: BackendInstaller.Receipt] = [:]
    @State private var busy: Set<GraphicsBackend> = []
    @State private var message: String?
    @State private var checking = false
    @State private var updateStatus: String?

    var body: some View {
        Section {
            ForEach(manifest.backends) { pin in
                LabeledContent {
                    if busy.contains(pin.backend) {
                        ProgressView().controlSize(.small)
                    } else {
                        offerView(pin)
                    }
                } label: {
                    Text(verbatim: pin.title)
                }
            }
            HStack {
                Button("Check for Updates") { Task { await checkForUpdates() } }
                    .disabled(checking)
                if checking { ProgressView().controlSize(.small) }
            }
            if let updateStatus {
                Text(updateStatus).foregroundStyle(.secondary)
            }
            if let message { Text(message).foregroundStyle(.red) }
        } header: {
            Text("Graphics Backends")
        }
        .task { refresh() }
    }

    private var hasUpdate: Bool {
        manifest.backends.contains { pin in
            if case .update = BackendInstaller.offer(pin, installed: installed[pin.backend]) { return true }
            return false
        }
    }

    // The check only refreshes the signed manifest. Installing an update stays a separate button.
    private func checkForUpdates() async {
        guard !checking else { return }
        checking = true
        updateStatus = nil
        defer { checking = false }
        guard let feed = BackendManifest.feed else {
            updateStatus = String(localized: "The graphics backend update feed is unavailable. Your installed backends are unchanged.")
            return
        }
        let outcome = await BackendManifest.refresh(from: feed)
        manifest = BackendManifest.current()
        switch outcome {
        case .updated:
            updateStatus = hasUpdate
                ? String(localized: "Graphics backend updates are available. Choose Update beside a backend.")
                : String(localized: "Graphics backend list updated. Your installed backends are up to date.")
        case .unchanged:
            updateStatus = hasUpdate
                ? String(localized: "Graphics backend updates are available. Choose Update beside a backend.")
                : String(localized: "Your installed graphics backends are up to date.")
        case .unavailable:
            updateStatus = String(localized: "The graphics backend update feed is unavailable. Your installed backends are unchanged.")
        case .rejected:
            updateStatus = String(localized: "The graphics backend update signature could not be verified. Your installed backends are unchanged.")
        }
    }

    // An update unpacks beside the installed copy and swaps it in, so games keep the old files until it is done
    @ViewBuilder
    private func offerView(_ pin: BackendManifest.Pin) -> some View {
        switch BackendInstaller.offer(pin, installed: installed[pin.backend]) {
        case .ready:
            Text("Ready").foregroundStyle(.secondary)
        case .download:
            Button("Download") { download(pin) }
        case .update(let version):
            Button(String(localized: "Update to \(version)")) { download(pin) }
        }
    }

    private func refresh() {
        installed = Dictionary(BackendInstaller.installed(in: folder).map { ($0.backend, $0) }, uniquingKeysWith: { a, _ in a })
        model?.backendAvailability.installed = Set(installed.keys)
    }

    private func download(_ pin: BackendManifest.Pin) {
        busy.insert(pin.backend)
        message = nil
        let syncTools = syncTools
        Task {
            do {
                try await BackendInstaller.install(pin, backends: folder)
                await Self.afterInstall(syncTools: syncTools, reload: model?.reloadRunners)
            } catch {
                message = (error as? StepFailure)?.detail ?? error.localizedDescription
            }
            busy.remove(pin.backend)
            refresh()
        }
    }

    // Steam's backend tool list only offers a backend once it is written there
    @MainActor
    static func afterInstall(syncTools: @escaping @Sendable () throws -> Void, reload: (@MainActor () async -> Void)?) async {
        do {
            try await Task.detached { try syncTools() }.value
        } catch {
            AppLog.note("tool list sync after a backend download failed: \(error)")
        }
        await reload?()
    }
}
