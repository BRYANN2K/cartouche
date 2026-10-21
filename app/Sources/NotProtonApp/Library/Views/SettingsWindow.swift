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
    case general, library, accounts, steam, prefixes, compatibility, privacy, consoles, controllers, agents, advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: String(localized: "General")
        case .library: String(localized: "Library")
        case .accounts: String(localized: "Accounts")
        case .steam: String(localized: "Steam")
        case .prefixes: String(localized: "Wine Prefixes")
        case .compatibility: String(localized: "Runners")
        case .privacy: String(localized: "Privacy")
        case .consoles: String(localized: "Consoles")
        case .controllers: String(localized: "Controllers")
        case .agents: String(localized: "Agents")
        case .advanced: String(localized: "Advanced")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .library: "square.grid.2x2"
        case .accounts: "person.crop.circle"
        case .steam: "link"
        case .prefixes: "externaldrive"
        case .compatibility: "cpu"
        case .privacy: "hand.raised"
        case .consoles: "gamecontroller"
        case .controllers: "gamecontroller.fill"
        case .agents: "brain.head.profile"
        case .advanced: "wrench.and.screwdriver"
        }
    }
}

struct SettingsWindow: View {
    let model: LibraryModel
    let permissions: PermissionCenter
    let consoles: ConsolesSettingsModel
    let choices: PrivacyChoices

    // Keep the selected destination across Settings opens.
    static let tabKey = "settings.tab"

    @AppStorage(tabKey) private var tab: SettingsTab = .general
    @Environment(ControlsCenter.self) private var controls: ControlsCenter?
    @Environment(ConsoleCenter.self) private var consoleCenter: ConsoleCenter?
    @Environment(AgentControlModel.self) private var agents: AgentControlModel?

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 3) {
                    ForEach(SettingsTab.allCases) { item in
                        SidebarRow(title: item.title, badge: nil, selected: tab == item,
                                   icon: { Image(systemName: item.symbol) }) {
                            tab = item
                        }
                        .accessibilityAddTraits(tab == item ? .isSelected : [])
                    }
                }
                .padding(10)
            }
            .focusable()
            .focusEffectDisabled()
            .onKeyPress(.upArrow) { step(-1) }
            .onKeyPress(.downArrow) { step(1) }
            .frame(width: 184)
            .background(.ultraThinMaterial)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                Text(tab.title)
                    .font(.title2.weight(.semibold))
                    .padding(.horizontal, 24)
                    .padding(.top, 22)
                    .padding(.bottom, 8)
                    .accessibilityAddTraits(.isHeader)
                pane(tab)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 900, height: 640)
        .onAppear(perform: followRoute)
        .onChange(of: SettingsRoute.shared.tab) { followRoute() }
        .scrollBounceBehavior(.basedOnSize, axes: [.vertical, .horizontal])
    }

    private func step(_ offset: Int) -> KeyPress.Result {
        let tabs = SettingsTab.allCases
        guard let current = tabs.firstIndex(of: tab) else { return .ignored }
        let next = current + offset
        if tabs.indices.contains(next) { tab = tabs[next] }
        return .handled
    }

    private func followRoute() {
        guard let next = SettingsRoute.shared.tab else { return }
        tab = next
        SettingsRoute.shared.tab = nil
    }

    @ViewBuilder
    private func pane(_ tab: SettingsTab) -> some View {
        switch tab {
        case .general: GeneralSettingsView()
        case .library: LibrarySettingsView(model: model)
        case .accounts: AccountsSettingsView(model: model)
        case .steam: StatusView()
        case .prefixes: WinePrefixesSettingsView()
        case .compatibility: CompatibilitySettingsView(model: model)
        case .privacy: PrivacySettingsView(center: permissions, choices: choices)
        case .consoles: ConsolesSettingsView(model: consoles, extras: consoleCenter?.extras, emulators: consoleCenter?.emulators)
        case .controllers: if let controls { ControllersSettingsView(center: controls) }
        case .agents: if let agents { AgentsSettingsView(model: agents) }
        case .advanced: AdvancedSettingsView()
        }
    }

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

    var body: some View {
        Form {
            Section("PC Games") {
                Toggle("Show games that are not installed", isOn: $model.showNotInstalled)
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

// Collect Diagnostics writes a zip on the Desktop with Cartouche's own crash
// reports and logs — nothing is sent anywhere.
struct AdvancedSettingsView: View {
    @State private var collecting = false
    @State private var collectError: String?

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    Button(collecting ? String(localized: "Collecting…") : String(localized: "Collect Diagnostics…")) {
                        collect()
                    }
                    .disabled(collecting)
                } label: {
                    Text("Diagnostics")
                    Text("Crash reports and the last lines of Cartouche’s logs, zipped on your Desktop.")
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("Nothing is sent anywhere. The zip is for attaching to a bug report.")
            }
        }
        .formStyle(.grouped)
        .alert(String(localized: "Diagnostics"), isPresented: Binding(
            get: { collectError != nil }, set: { if !$0 { collectError = nil } })
        ) {} message: {
            if let collectError { Text(verbatim: collectError) }
        }
    }

    @MainActor
    private func collect() {
        collecting = true
        Task {
            do {
                let zip = try await Task.detached(priority: .userInitiated) {
                    try Diagnostics.collect(
                        into: FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
                            ?? SupportPaths.home.appending(path: "Desktop"),
                        reportsFrom: CrashReports.directory,
                        logsFrom: SupportPaths.logs,
                        home: SupportPaths.home)
                }.value
                NSWorkspace.shared.activateFileViewerSelecting([zip])
            } catch {
                collectError = error.localizedDescription
            }
            collecting = false
        }
    }
}

struct CompatibilitySettingsView: View {
    let model: LibraryModel
    @Environment(RunnersModel.self) private var runners: RunnersModel?

    var body: some View {
        Form {
            ThisMacSection()
            if let runners {
                RunnersSection(model: runners)
            } else {
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
            }
            BackendDownloadsSection(model: model)
            SetupDefaultsSection(model: model)
            Section {
                Text("D3DMetal is never bundled. It comes from your own Game Porting Toolkit or CrossOver.")
                    .foregroundStyle(.secondary)
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
