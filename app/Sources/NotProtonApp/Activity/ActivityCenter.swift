// Owns what the activity slot shows: the running game, the install from
// InstallCenter, a store client's job, Steam's downloads and the updates.
// Reads Steam's own files off the main thread, tells Steam to pause or cancel,
// and announces the end of a download or an install.

import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class ActivityCenter {

    static let shared = ActivityCenter()

    // A game that finished downloading keeps its cover effect this long, for the finish ring
    nonisolated static let finishFlash: Duration = .milliseconds(1100)

    private(set) var steamGame: RunningGame?
    // Set by the console library (P13) while RetroArch plays
    var consoleGame: RunningGame?
    // Or read from it: what RetroArch plays now (P13's ConsoleCenter)
    @ObservationIgnored var consoleSource: @MainActor () -> RunningGame? = { nil }
    // The running store job, from StoreCenter (P10); the app sets both
    @ObservationIgnored var storeSource: @MainActor () -> StoreActivity? = { nil }
    @ObservationIgnored var stopStore: @MainActor (StoreActivity) -> Void = { _ in }
    private(set) var downloads: [DownloadActivity] = []
    // Runner and backend updates; their phases fill this in
    var updates: [UpdateActivity] = []
    // Downloads that just finished, by app ID, for the reveal's finish ring
    private(set) var finishing: [Int: Date] = [:]
    // The last thing that went wrong while asking Steam, in words for the user
    private(set) var problem: String?

    @ObservationIgnored let installs: InstallCenter
    @ObservationIgnored var reader: SteamActivityReader
    @ObservationIgnored var control: any SteamDownloadControlling
    @ObservationIgnored var processes: GameProcesses
    @ObservationIgnored var notifier: any ActivityNotifying
    // Set by the host so the first finished download offers notifications (P17)
    @ObservationIgnored var permissionFlow: PermissionFlow?
    // Notifications only go out while Cartouche is in the background
    @ObservationIgnored var isAppActive: @MainActor () -> Bool = { NSApp?.isActive ?? false }
    // The library reloads Steam's installed games when a download ends
    @ObservationIgnored var onDownloadFinished: @MainActor (Int) -> Void = { _ in }
    // Frames per second of the running game, from P8's counter
    @ObservationIgnored var fps: @MainActor (RunningGame) -> Int? = { _ in nil }
    // Quits the console session (P13)
    @ObservationIgnored var quitConsole: @MainActor () async -> Void = {}
    @ObservationIgnored var now: () -> Date = { Date() }
    @ObservationIgnored private var watcher: Task<Void, Never>?
    // App IDs the user asked to pause or resume, until Steam's files agree
    @ObservationIgnored private var asked: [Int: (state: DownloadActivity.State, at: Date)] = [:]
    @ObservationIgnored private var hasRead = false
    @ObservationIgnored private var tracked: [pid_t] = []

    init(installs: InstallCenter? = nil, reader: SteamActivityReader = SteamActivityReader(),
         control: (any SteamDownloadControlling)? = nil, processes: GameProcesses = GameProcesses(),
         notifier: (any ActivityNotifying)? = nil) {
        self.installs = installs ?? .shared
        self.reader = reader
        self.control = control ?? SteamDownloadCommands()
        self.processes = processes
        self.notifier = notifier ?? UserActivityNotifier()
    }

    var playing: RunningGame? {
        guard var game = consoleGame ?? consoleSource() ?? steamGame else { return nil }
        game.fps = game.fps ?? fps(game)
        return game
    }

    var slot: ActivitySlot? {
        ActivitySlot.pick(playing: playing, install: installs.activity, store: storeSource(),
                          downloads: downloads, updates: updates)
    }

    var menuSections: [ActivityMenuSection] {
        ActivityMenuSection.all(playing: playing, install: installs.activity, store: storeSource(),
                                downloads: downloads, updates: updates)
    }

    func download(for game: Game) -> DownloadActivity? {
        guard game.source == .steam, let appID = game.steamAppID else { return nil }
        return downloads.first { $0.appID == appID }
    }

    // Where the cover's color has risen to, nil when the game is not downloading
    func reveal(for game: Game) -> CoverReveal.Progress? {
        guard let appID = game.steamAppID, game.source == .steam else { return nil }
        if let started = finishing[appID] { return CoverReveal.Progress(fraction: 1, finishedAt: started) }
        guard let download = downloads.first(where: { $0.appID == appID }), !download.isFailed else { return nil }
        return CoverReveal.Progress(fraction: download.fraction, finishedAt: nil)
    }

    // MARK: Reading Steam

    func watch(every interval: Duration = .seconds(1)) {
        watcher?.cancel()
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: interval)
            }
        }
    }

    func stopWatching() {
        watcher?.cancel()
        watcher = nil
    }

    func refresh() async {
        let reader = reader
        let snapshot = await Task.detached { reader.read() }.value
        apply(snapshot)
    }

    func apply(_ snapshot: SteamActivitySnapshot) {
        let before = Dictionary(downloads.map { ($0.appID, $0) }, uniquingKeysWith: { first, _ in first })
        var next = snapshot.downloads.map(settle)
        // A pause or resume shows at once; Steam's files catch up within a few seconds
        for i in next.indices {
            if let ask = asked[next[i].appID], !next[i].isFailed { next[i].state = ask.state }
        }
        // The first read only learns what was already going on
        if hasRead {
            for (appID, old) in before where !next.contains(where: { $0.appID == appID }) && snapshot.installed.contains(appID) {
                finished(old)
            }
            for item in next {
                if case .failed(let reason) = item.state, before[item.appID].map({ !$0.isFailed }) ?? true {
                    failed(item, reason: reason)
                }
            }
        }
        hasRead = true
        downloads = next
        tracked = snapshot.trackedPIDs
        steamGame = snapshot.runningAppID.map { appID in
            RunningGame(id: "steam:\(appID)", name: snapshot.names[appID] ?? String(localized: "A Steam game"),
                        target: .steam(appID: appID))
        }
        let cutoff = now().addingTimeInterval(-Self.seconds(Self.finishFlash) - 0.2)
        finishing = finishing.filter { $0.value > cutoff }
    }

    // Drops a pause or resume once Steam's files show it, or after 10 seconds
    private func settle(_ item: DownloadActivity) -> DownloadActivity {
        guard let ask = asked[item.appID] else { return item }
        if item.state == ask.state || now().timeIntervalSince(ask.at) > 10 { asked[item.appID] = nil }
        return item
    }

    private func finished(_ download: DownloadActivity) {
        asked[download.appID] = nil
        finishing[download.appID] = now()
        onDownloadFinished(download.appID)
        if let flow = permissionFlow { NotificationOffer.offer(after: .downloadFinished, flow: flow) }
        if !isAppActive() { notifier.ready(name: download.name, appID: download.appID) }
    }

    private func failed(_ download: DownloadActivity, reason: String) {
        if !isAppActive() { notifier.downloadFailed(name: download.name, appID: download.appID, reason: reason) }
    }

    nonisolated static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    // MARK: Actions

    func pause(_ appID: Int) {
        guard let i = downloads.firstIndex(where: { $0.appID == appID }) else { return }
        if ask(appID, .paused, { try $0.pause(appID: appID) }) { downloads[i].state = .paused }
    }

    func resume(_ appID: Int) {
        guard let i = downloads.firstIndex(where: { $0.appID == appID }) else { return }
        if ask(appID, .downloading, { try $0.resume(appID: appID) }) { downloads[i].state = .downloading }
    }

    func togglePause(_ appID: Int) {
        guard let item = downloads.first(where: { $0.appID == appID }) else { return }
        item.isPaused ? resume(appID) : pause(appID)
    }

    // Steam asks for confirmation and removes what was downloaded
    func cancel(_ appID: Int) {
        do {
            try control.cancel(appID: appID)
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }

    // Asks Steam again for a failed download
    func retry(_ appID: Int) {
        do {
            try control.retry(appID: appID)
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }

    private func ask(_ appID: Int, _ state: DownloadActivity.State, _ send: (any SteamDownloadControlling) throws -> Void) -> Bool {
        do {
            try send(control)
            asked[appID] = (state, now())
            problem = nil
            return true
        } catch {
            problem = error.localizedDescription
            return false
        }
    }

    // Console sessions share the slot: "Playing on RetroArch", and Quit goes to RetroArch (P13)
    func follow(_ consoles: ConsoleCenter) {
        consoleSource = { [weak consoles] in
            guard let consoles, let playing = consoles.playing, let game = consoles.game(playing.gameID) else { return nil }
            return RunningGame(id: game.id, name: game.name, target: .console, starting: playing.phase == .starting,
                               emulator: playing.emulator)
        }
        quitConsole = { [weak consoles] in await consoles?.quit() }
    }

    func quitGame() async {
        guard let game = playing else { return }
        switch game.target {
        case .console:
            await quitConsole()
            consoleGame = nil
        case .steam(let appID):
            let processes = processes, tracked = tracked
            let folder = reader.files.installFolder(appID: appID)
            let quit = await Task.detached { processes.quit(appID: appID, tracked: tracked, installFolder: folder) }.value
            if quit > 0 { steamGame = nil }
        }
    }
}
