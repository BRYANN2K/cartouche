import RetroArchKit
import SwiftUI

enum AfterLaunch: String, CaseIterable, Identifiable {
    case hide, keepOpen, quit

    static let key = "general.afterLaunch"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hide: String(localized: "Hide Cartouche")
        case .keepOpen: String(localized: "Keep Cartouche Open")
        case .quit: String(localized: "Quit Cartouche")
        }
    }
}

enum GeneralSettings {
    static let showInMenuBarKey = "general.showInMenuBar"
}

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, library, accounts, compatibility, privacy, consoles, controllers

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: String(localized: "General")
        case .library: String(localized: "Library")
        case .accounts: String(localized: "Accounts")
        case .compatibility: String(localized: "Compatibility")
        case .privacy: String(localized: "Privacy")
        case .consoles: String(localized: "Consoles")
        case .controllers: String(localized: "Controllers")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .library: "square.grid.2x2"
        case .accounts: "person.crop.circle"
        case .compatibility: "cpu"
        case .privacy: "hand.raised"
        case .consoles: "gamecontroller"
        case .controllers: "gamecontroller.fill"
        }
    }
}

struct SettingsWindow: View {
    let model: LibraryModel
    let permissions: PermissionCenter
    let consoles: ConsolesSettingsModel

    @State private var tab: SettingsTab = .general
    @Environment(ControlsCenter.self) private var controls: ControlsCenter?
    // Achievements, iCloud Drive and translation in Settings > Consoles (P14); emulators (P16)
    @Environment(ConsoleCenter.self) private var consoleCenter: ConsoleCenter?

    var body: some View {
        TabView(selection: $tab) {
            ForEach(SettingsTab.allCases) { tab in
                pane(tab)
                    .tabItem { Label(tab.title, systemImage: tab.symbol) }
                    .tag(tab)
            }
        }
        .frame(width: 640, height: 560)
    }

    @ViewBuilder
    private func pane(_ tab: SettingsTab) -> some View {
        switch tab {
        case .general: GeneralSettingsView()
        case .library: LibrarySettingsView(model: model)
        case .accounts: AccountsSettingsView(model: model)
        case .compatibility: CompatibilitySettingsView(model: model)
        case .privacy: PrivacySettingsView(center: permissions)
        case .consoles: ConsolesSettingsView(model: consoles, extras: consoleCenter?.extras, emulators: consoleCenter?.emulators)
        case .controllers: if let controls { ControllersSettingsView(center: controls) }
        }
    }

    // Cartouche's own RetroArch folder, never the user's
    static let retroArchPaths = RetroArchPaths(root: SupportPaths.support.appending(path: "retroarch", directoryHint: .isDirectory))

    @MainActor
    static func consolesModel(
        cores: CoreManager = CoreManager(paths: retroArchPaths, source: .qa)
    ) -> ConsolesSettingsModel {
        ConsolesSettingsModel(
            paths: retroArchPaths,
            includedApp: Bundle.main.bundleURL.appending(path: "Contents/Helpers/RetroArch.app"),
            cores: cores,
            official: OfficialRelease(paths: retroArchPaths, base: QAEnvironment.url(OfficialRelease.stable)))
    }
}

struct GeneralSettingsView: View {
    @AppStorage(GeneralSettings.showInMenuBarKey) private var showInMenuBar = true
    @AppStorage(AfterLaunch.key) private var afterLaunch = AfterLaunch.hide

    var body: some View {
        Form {
            Section {
                Toggle("Show in menu bar", isOn: $showInMenuBar)
                Picker("When a game starts", selection: $afterLaunch) {
                    ForEach(AfterLaunch.allCases) { Text($0.title).tag($0) }
                }
            }
            UpdatesSection()
            SetupAssistantSection()
        }
        .formStyle(.grouped)
    }
}

struct LibrarySettingsView: View {
    @Bindable var model: LibraryModel
    @State private var steamPath = SupportPaths.Steam.app.path(percentEncoded: false)

    var body: some View {
        Form {
            Section("PC Games") {
                Toggle("Show games that are not installed", isOn: $model.showNotInstalled)
                LabeledContent("Steam") {
                    HStack {
                        Text(verbatim: steamPath).font(.callout.monospaced()).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                        Button("Locate Steam…") {
                            if let app = SteamInstallView.chooseSteam(), SteamSetup().locate(app) {
                                steamPath = app.path(percentEncoded: false)
                                Task { await model.load() }
                            }
                        }
                    }
                }
            }
            Section {
                if model.hiddenGames.isEmpty {
                    Text("No hidden games").foregroundStyle(.secondary)
                }
                ForEach(model.hiddenGames) { game in
                    LabeledContent(game.name) {
                        Button("Show") { model.unhide(game.id) }
                    }
                }
            } header: {
                Text("Hidden Games")
            } footer: {
                Text("Hidden games stay installed. They are left out of the library and search.")
            }
            LibraryFoldersSection()
        }
        .formStyle(.grouped)
    }
}

struct AccountsSettingsView: View {
    let model: LibraryModel
    @Environment(StoreCenter.self) private var stores: StoreCenter?

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    Button("Open Steam") { NSWorkspace.shared.open(SupportPaths.Steam.app) }
                        .disabled(model.steam.presence == .notInstalled)
                } label: {
                    Text(verbatim: "Steam")
                    Text(steamLine).foregroundStyle(.secondary)
                }
                ForEach([GameSource.epic, .gog, .amazon]) { store in
                    StoreAccountRow(source: store, center: stores)
                }
            } footer: {
                Text("Login tokens are kept in your Keychain. You sign in on each store’s own page.")
            }
        }
        .formStyle(.grouped)
    }

    private var steamLine: String {
        switch model.steam.presence {
        case .notInstalled: return String(localized: "Not installed")
        case .closed, .running:
            return model.steam.account.map { String(localized: "Signed in as \($0.accountName)") }
                ?? String(localized: "Not signed in")
        }
    }
}

struct CompatibilitySettingsView: View {
    let model: LibraryModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            SetupDefaultsSection(model: model)
            BackendDownloadsSection(model: model)
            Section("Runners") {
                if model.runners.isEmpty {
                    Text("No runner found on this Mac yet").foregroundStyle(.secondary)
                }
                ForEach(model.runners) { runner in
                    LabeledContent {
                        Text(Self.state(runner)).foregroundStyle(.secondary)
                    } label: {
                        Text(verbatim: "\(runner.kind.name) \(runner.displayVersion)")
                        if let source = runner.source {
                            Text(verbatim: source.path(percentEncoded: false)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            FreeRunnerSection()
            Section {
                LabeledContent {
                    Button("Open Steam Play Setup") { openWindow(id: CartoucheApp.setupWindow) }
                } label: {
                    Text("Steam Play Setup")
                    Text("Install Cartouche into Steam, repair it, and manage prefixes and backups.")
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("D3DMetal is never bundled. It comes from your own Game Porting Toolkit or CrossOver.")
            }
        }
        .formStyle(.grouped)
    }

    static func state(_ runner: Runner) -> String {
        switch runner.state {
        case .available: String(localized: "Not set up")
        case .installing: String(localized: "Setting up…")
        case .ready: String(localized: "Ready")
        case .damaged: String(localized: "Damaged")
        case .unsupported: String(localized: "Not supported")
        }
    }
}
