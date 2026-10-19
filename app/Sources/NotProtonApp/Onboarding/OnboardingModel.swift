// The first launch: five skippable steps, from what Cartouche found on this Mac
// to a game ready to play. Only the PC games step may ask macOS for anything
// (App Management, through the Steam step), and only when the user sets Steam up.

import Foundation
import Observation
import RetroArchKit

// The free runner the PC games step offers
struct RunnerOffer: Sendable {
    var build: @Sendable () -> RunnerManifest.Build?
    var isInstalled: @Sendable (String) -> Bool
    var install: @Sendable (RunnerManifest.Build) async throws -> Void

    static var live: RunnerOffer {
        RunnerOffer(
            build: { recommended(RunnerManifest.current()) },
            isInstalled: { WineRunnerInstaller.isInstalled($0) },
            install: { _ = try await WineRunnerInstaller.install($0) })
    }

    // Cartouche's own build of CrossOver's Wine when the manifest has one
    static func recommended(_ manifest: RunnerManifest) -> RunnerManifest.Build? {
        manifest.builds.first { $0.origin == .cartouche } ?? manifest.builds.first
    }
}

// What the Consoles step adds through RetroArchKit
struct ConsoleSetup: Sendable {
    var added: @Sendable () async -> [String]
    var add: @Sendable (String) async throws -> Void
    var bios: @Sendable (Console) -> BIOSStatus
    var biosFolder: URL

    static func live(paths: RetroArchPaths, source: CoreSource = .buildbot, session: URLSession = .shared) -> ConsoleSetup {
        let shelf = ConsoleShelf(paths: paths, cores: CoreManager(paths: paths, source: source, session: session))
        return ConsoleSetup(
            added: { await shelf.added().map(\.id) },
            add: { try await shelf.add($0) },
            bios: { BIOSChecker(paths: paths).status(for: $0) },
            biosFolder: paths.bios)
    }
}

@MainActor
@Observable
final class OnboardingModel {

    enum RunnerPhase: Equatable {
        case none
        case notInstalled
        case downloading
        case installed
        case failed(String)
    }

    private(set) var state: OnboardingState
    // Reopened midway: shows "Welcome back" and Start Over
    private(set) var resumed = false
    var isPresented = false
    private(set) var findings: MacFindings?
    private(set) var runner: RunnerManifest.Build?
    private(set) var runnerPhase: RunnerPhase = .none
    // Consoles already on the shelf, from Settings or an earlier onboarding
    private(set) var shelf: [String] = []
    private(set) var addingConsoles = false
    private(set) var consoleProblem: String?

    let steamStep: SteamStep
    @ObservationIgnored let store: OnboardingStore
    @ObservationIgnored let scan: MacScan
    @ObservationIgnored let runners: RunnerOffer
    @ObservationIgnored let consoles: ConsoleSetup
    @ObservationIgnored let folders: GameFolders
    @ObservationIgnored let privacy: PrivacyChoices
    @ObservationIgnored let library: LibraryModel
    @ObservationIgnored var play: @MainActor (Game) -> Void = { _ in }

    init(
        store: OnboardingStore = OnboardingStore(),
        scan: MacScan = .live,
        runners: RunnerOffer = .live,
        consoles: ConsoleSetup,
        steamStep: SteamStep,
        folders: GameFolders,
        privacy: PrivacyChoices,
        library: LibraryModel
    ) {
        self.store = store
        self.scan = scan
        self.runners = runners
        self.consoles = consoles
        self.steamStep = steamStep
        self.folders = folders
        self.privacy = privacy
        self.library = library
        state = store.load() ?? OnboardingState()
    }

    var step: OnboardingStep { state.step }

    // Never finished nor skipped
    var isDue: Bool { !state.finished }

    // At launch: the first launch, or the step where the last one stopped
    func presentIfDue() {
        guard isDue else { return }
        resumed = state.step != .welcome
        isPresented = true
    }

    // After a relaunch the relaunch service asked for, on the step it saved
    func reopen(on route: ScreenRoute) {
        guard route.screen == "onboarding", let step = route.detail.flatMap(OnboardingStep.init(rawValue:)) else { return }
        state.finished = false
        state.step = step
        save()
        resumed = false
        isPresented = true
    }

    // Settings > General
    func runAgain() {
        startOver()
        isPresented = true
    }

    func startOver() {
        let added = state.addedConsoles
        state = OnboardingState()
        state.addedConsoles = added
        resumed = false
        save()
        Task { await prepare() }
    }

    // Reads what the steps show. Changes nothing on disk.
    func prepare() async {
        if findings == nil { findings = await scan.run() }
        prepareRunner()
        shelf = await consoles.added()
        pickFoundConsoles()
        offerFoundFolders()
    }

    // MARK: Moving between steps

    func next() {
        guard let next = state.step.next else { return finish() }
        if state.step == .folders { applyFolders() }
        go(to: next)
    }

    func back() {
        if let previous = state.step.previous { go(to: previous) }
    }

    // Leaves the step as it is: nothing it offers is done
    func skip() {
        guard let next = state.step.next else { return finish() }
        go(to: next)
    }

    // Skip Setup, on Welcome: the library opens and nothing was changed
    func skipAll() {
        finish()
    }

    func finish() {
        state.finished = true
        save()
        resumed = false
        isPresented = false
    }

    private func go(to step: OnboardingStep) {
        state.step = step
        resumed = false
        save()
    }

    private func save() {
        store.save(state)
    }

    // MARK: PC games

    var canContinue: Bool {
        switch state.step {
        case .pcGames: steamStep.canContinue
        case .consoles: !addingConsoles
        default: true
        }
    }

    // The recommended build and whether it is in the runners folder already
    func prepareRunner() {
        let build = runners.build()
        runner = build
        if runnerPhase != .downloading {
            runnerPhase = build.map { runners.isInstalled($0.id) ? .installed : .notInstalled } ?? .none
        }
    }

    func downloadRunner() async {
        guard let build = runner, runnerPhase != .downloading else { return }
        runnerPhase = .downloading
        do {
            try await runners.install(build)
            runnerPhase = runners.isInstalled(build.id) ? .installed : .failed(String(localized: "The download did not install."))
        } catch let failure as StepFailure {
            runnerPhase = .failed(failure.detail)
        } catch {
            runnerPhase = .failed(error.localizedDescription)
        }
    }

    // MARK: Consoles

    var picked: Set<String> { Set(state.consoles) }

    func isPicked(_ console: Console) -> Bool { picked.contains(console.id) || shelf.contains(console.id) }

    func isAdded(_ console: Console) -> Bool { shelf.contains(console.id) || state.addedConsoles.contains(console.id) }

    func toggle(_ console: Console) {
        guard !shelf.contains(console.id) else { return }
        if let i = state.consoles.firstIndex(of: console.id) {
            state.consoles.remove(at: i)
        } else {
            state.consoles.append(console.id)
        }
        state.consolesChosen = true
        save()
    }

    // Picked and not on the shelf yet: what the primary button downloads
    var consolesToAdd: [Console] {
        ConsoleCatalog.all.filter { picked.contains($0.id) && !isAdded($0) }
    }

    // BIOS status of the picked consoles that need one
    var biosNotes: [BIOSStatus] {
        ConsoleCatalog.all
            .filter { isPicked($0) && $0.bios != .none }
            .map { consoles.bios($0) }
    }

    func foundGames(_ console: Console) -> Int { findings?.consoleGames[console.id] ?? 0 }

    // Downloads the cores of the picked consoles, one each, then moves on
    func addConsoles() async {
        guard !addingConsoles else { return }
        addingConsoles = true
        consoleProblem = nil
        for console in consolesToAdd {
            do {
                try await consoles.add(console.id)
                state.addedConsoles.append(console.id)
                save()
            } catch {
                consoleProblem = error.localizedDescription
                break
            }
        }
        shelf = await consoles.added()
        addingConsoles = false
        if consoleProblem == nil { next() }
    }

    // Consoles with games in a found folder start picked, until the user picks
    private func pickFoundConsoles() {
        guard !state.consolesChosen, state.consoles.isEmpty, let found = findings?.consoleGames, !found.isEmpty else { return }
        state.consoles = ConsoleCatalog.all.map(\.id).filter { found[$0] != nil }
        save()
    }

    // MARK: Folders and privacy

    struct FolderRow: Identifiable, Equatable {
        let url: URL
        // Nil for a folder the user added, which was not looked into
        let found: FoundFolder?
        var id: String { url.plainPath }
    }

    // Found folders first, then the ones the user added
    var folderRows: [FolderRow] {
        let found = findings?.folders ?? []
        let added = state.folders.keys.sorted().filter { path in !found.contains { $0.id == path } }
        return found.map { FolderRow(url: $0.url, found: $0) }
            + added.map { FolderRow(url: URL(filePath: $0, directoryHint: .isDirectory), found: nil) }
    }

    func keepsFolder(_ id: String) -> Bool { state.folders[id] ?? true }

    func setKeepsFolder(_ id: String, _ keep: Bool) {
        state.folders[id] = keep
        save()
    }

    func addFolder(_ folder: URL) {
        state.folders[folder.plainPath] = true
        save()
    }

    // Found folders are kept unless the user turns them off
    private func offerFoundFolders() {
        var changed = false
        for folder in findings?.folders ?? [] where state.folders[folder.id] == nil {
            state.folders[folder.id] = true
            changed = true
        }
        if changed { save() }
    }

    // Only Continue keeps them; Skip leaves Settings as it was
    private func applyFolders() {
        for (path, keep) in state.folders.sorted(by: { $0.key < $1.key }) where keep {
            folders.add(URL(filePath: path, directoryHint: .isDirectory))
        }
    }

    // MARK: Ready

    // The installed game played last, else the first installed one
    var readyGame: Game? {
        let installed = library.allGames.filter { $0.installed && !library.isHidden($0.id) }
        let played = installed.filter { $0.lastPlayed != nil }.max { $0.lastPlayed! < $1.lastPlayed! }
        return played ?? installed.first
    }

    var readySummary: String {
        let steamGames = library.steam.games.count
        let consoleCount = Set(shelf + state.addedConsoles).count
        let games = steamGames == 1 ? String(localized: "1 Steam game") : String(localized: "\(steamGames) Steam games")
        let added = consoleCount == 1 ? String(localized: "1 console") : String(localized: "\(consoleCount) consoles")
        switch (steamGames > 0, consoleCount > 0) {
        case (true, true): return String(localized: "Your library has \(games) and \(added).")
        case (true, false): return String(localized: "Your library has \(games).")
        case (false, true): return String(localized: "Your library has \(added).")
        case (false, false): return String(localized: "Your library is ready for the games you add.")
        }
    }

    func playReadyGame() {
        guard let game = readyGame else { return }
        finish()
        play(game)
    }
}

// The Steam step's install: the Setup window's own, with App Management's
// refusal passed on as the write refusal the step reads
enum OnboardingSteam {
    struct Failed: LocalizedError {
        let errorDescription: String?
    }

    @MainActor
    static func install() async throws {
        let status = SystemStatus()
        await status.refresh()
        await status.installIntoSteam()
        guard let failure = status.failure else { return }
        if status.failureRemedy == .appManagement {
            throw WriteRefused(path: SupportPaths.Steam.deployedDylib.path(percentEncoded: false))
        }
        throw Failed(errorDescription: failure)
    }
}
