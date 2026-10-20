import Foundation
import RetroArchKit
import SwiftUI

struct CartoucheApp: App {

    static let mainWindow = "main"
    static let setupWindow = "setup"
    static let signInWindow = "store-sign-in"

    @State var status = SystemStatus()
    @State var prefixes = PrefixesModel()
    @State var pane: Pane = .status
    @State var library: LibraryModel
    @State var compat: CompatibilityModel
    @State var steamSetup = SteamSetup()
    @State var permissions: PermissionCenter
    @State var permissionFlow: PermissionFlow
    @State var controls: ControlsCenter
    @State var consoles: ConsolesSettingsModel
    @State var consoleCenter: ConsoleCenter
    @State var network = NetworkWatch()
    @State var gameFolders = GameFolders()
    @State var relaunch: RelaunchService
    @State var onboarding: OnboardingModel?
    @State var performance = PerformanceModel()
    @State var runners: RunnersModel
    @State var stores: StoreCenter
    @State private var agents: AgentControlModel
    @AppStorage(GeneralSettings.showInMenuBarKey) private var showInMenuBar = true
    @AppStorage(AfterLaunch.key) var afterLaunch = AfterLaunch.hide
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State var started = false
    let updater = AppUpdater()
    private let agentBackend: AgentLiveBackend

    init() {
        // A write into a dead child's pipe fails with EPIPE, not a fatal SIGPIPE
        signal(SIGPIPE, SIG_IGN)
        try? FileManager.default.createDirectory(at: SupportPaths.support, withIntermediateDirectories: true)
        AppLog.start()
        if let qa = QAEnvironment.base { AppLog.note("QA mode: network base URLs re-point to \(qa.absoluteString)") }
        let permissions = PermissionCenter.live()
        _permissions = State(initialValue: permissions)
        _permissionFlow = State(initialValue: PermissionFlow(center: permissions))
        let library = LibraryModel()
        let controls = ControlsCenter(
            permissions: permissions, files: ControlsFiles(retroArch: SettingsWindow.retroArchPaths))
        _controls = State(initialValue: controls)
        let cores = CoreManager(paths: SettingsWindow.retroArchPaths, source: .qa)
        let consoles = SettingsWindow.consolesModel(cores: cores)
        let consoleCenter = ConsoleCenter(settings: consoles, cores: cores, library: library)
        let compat = CompatibilityModel()
        let runners = RunnersModel()
        runners.chooseToolkitFolder = ToolkitFolderPicker.choose
        _relaunch = State(initialValue: RelaunchService(
            games: CompositeGameActivity([RunnerGameActivity(), ConsoleGameActivity(center: consoleCenter)])))
        _runners = State(initialValue: runners)
        _library = State(initialValue: library)
        _consoles = State(initialValue: consoles)
        _consoleCenter = State(initialValue: consoleCenter)
        _compat = State(initialValue: compat)
        let storeCenter = StoreCenter.live(library: library)
        _stores = State(initialValue: storeCenter)
        // Off until the user turns it on (Settings > Agents).
        let backend = AgentLiveBackend(library: library, consoles: consoleCenter,
                                       installs: .shared, compat: compat, controls: controls,
                                       stores: storeCenter)
        agentBackend = backend
        _agents = State(initialValue: AgentControlModel(
            service: AgentService(backend: backend, providers: [AgentControls()])))
    }

    var body: some Scene {
        Window("Cartouche", id: Self.mainWindow) {
            LibraryWindow(model: library, compat: compat, steamSetup: steamSetup, actions: actions)
                .environment(consoleCenter)
                .environment(controls)
                .controlsSheet(controls)
                .frame(minWidth: 900, minHeight: 560)
                .permissionExplanations(permissionFlow)
                .sheet(isPresented: Binding(get: { onboarding?.isPresented ?? false },
                                            set: { onboarding?.isPresented = $0 })) {
                    if let onboarding { OnboardingView(model: onboarding).interactiveDismissDisabled() }
                }
                .environment(performance)
                .environment(stores)
                .storeSignIn(stores)
                .agentApprovals(agents)
                .task { await start() }
                .onChange(of: onboarding?.isPresented ?? false) { _, shown in
                    if shown == false { Task { await consoleCenter.reload(); await consoleCenter.rescanFolders() } }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    Task { await performance.refreshIfNeeded() }
                }
        }
        .defaultSize(width: 1280, height: 820)
        .commands { menus }

        Window("Steam Play Setup", id: Self.setupWindow) {
            RootView(pane: $pane)
                .environment(status)
                .environment(prefixes)
                .frame(minWidth: 720, minHeight: 460)
                .onChange(of: pane) { prefixes.forgetOutcome() }
                .onChange(of: status.snapshot?.installedRunners.map(\.id)) {
                    if prefixes.hasLoaded { Task { await prefixes.load() } }
                    Task { await loadRunners() }
                }
        }
        .defaultSize(width: 900, height: 760)

        Window("Sign In", id: Self.signInWindow) {
            StoreSignInWindow(center: stores)
        }
        .defaultSize(width: 560, height: 760)

        Settings {
            SettingsWindow(model: library, permissions: permissions, consoles: consoles, choices: compat.choices)
                .environment(consoleCenter)
                .environment(runners)
                .environment(onboarding)
                .environment(gameFolders)
                .environment(stores)
                .environment(controls)
                .storeSignIn(stores)
                .environment(agents)
                .onChange(of: runners.registry.runners) { _, _ in Task { await syncRunnerList() } }
        }

        // AppKit re-reports the item's visibility on every update; writing the same value back
        // into the defaults would refresh the scene again, endlessly
        MenuBarExtra(isInserted: Binding(get: { showInMenuBar },
                                         set: { if $0 != showInMenuBar { showInMenuBar = $0 } })) {
            StatusItemMenu(model: library, actions: actions)
        } label: {
            if NSImage(named: "MenuBarGlyph") != nil {
                Image("MenuBarGlyph")
            } else {
                Image(systemName: "gamecontroller")
            }
        }
    }
}
