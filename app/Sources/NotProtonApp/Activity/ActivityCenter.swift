
import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class ActivityCenter {

    static let shared = ActivityCenter()

    nonisolated static let finishFlash: Duration = .milliseconds(1100)

    private(set) var steamGame: RunningGame?
    @ObservationIgnored var consoleSource: @MainActor () -> RunningGame? = { nil }
    @ObservationIgnored var storeSource: @MainActor () -> StoreActivity? = { nil }
    @ObservationIgnored var stopStore: @MainActor (StoreActivity) -> Void = { _ in }
    private(set) var downloads: [DownloadActivity] = []
    private(set) var finishing: [Int: Date] = [:]
    private(set) var problem: String?

    @ObservationIgnored let installs: InstallCenter
    @ObservationIgnored var reader: SteamActivityReader
    @ObservationIgnored var control: any SteamDownloadControlling
    @ObservationIgnored var processes: GameProcesses
    @ObservationIgnored var notifier: any ActivityNotifying
    @ObservationIgnored var permissionFlow: PermissionFlow?
    // Notifications only go out while Cartouche is in the background
    @ObservationIgnored var isAppActive: @MainActor () -> Bool = { NSApp?.isActive ?? false }
    @ObservationIgnored var onDownloadFinished: @MainActor (Int) -> Void = { _ in }
    @ObservationIgnored var onGameEnded: @MainActor () -> Void = {}
    @ObservationIgnored var quitConsole: @MainActor () async -> Void = {}
    @ObservationIgnored var now: () -> Date = { Date() }
    @ObservationIgnored private var watcher: Task<Void, Never>?
    // App IDs the user asked to pause or resume, until Steam's files agree
    @ObservationIgnored private var asked: [Int: (state: DownloadActivity.State, at: Date)] = [:]
    @ObservationIgnored private var hasRead = false
    @ObservationIgnored private var tracked: [pid_t: Date] = [:]

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
        consoleSource() ?? steamGame
    }

    var slot: ActivitySlot? {
        ActivitySlot.pick(playing: playing, install: installs.activity, store: storeSource(),
                          downloads: downloads)
    }

    var menuSections: [ActivityMenuSection] {
        ActivityMenuSection.all(playing: playing, install: installs.activity, store: storeSource(),
                                downloads: downloads)
    }

    func download(for game: Game) -> DownloadActivity? {
        guard game.source == .steam, let appID = game.steamAppID else { return nil }
        return downloads.first { $0.appID == appID }
    }

    func reveal(for game: Game) -> CoverReveal.Progress? {
        guard let appID = game.steamAppID, game.source == .steam else { return nil }
        if let started = finishing[appID] { return CoverReveal.Progress(fraction: 1, finishedAt: started) }
        guard let download = downloads.first(where: { $0.appID == appID }), !download.isFailed else { return nil }
        return CoverReveal.Progress(fraction: download.fraction, finishedAt: nil, animating: download.state == .downloading)
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
        // Assign only on change: @Observable reports every write, and this runs every second
        if downloads != next { downloads = next }
        tracked = snapshot.trackedPIDs
        let nextGame = snapshot.runningAppID.map { appID in
            RunningGame(id: "steam:\(appID)", name: snapshot.names[appID] ?? String(localized: "A Steam game"),
                        target: .steam(appID: appID))
        }
        if steamGame != nextGame {
            if steamGame != nil && nextGame == nil { onGameEnded() }
            steamGame = nextGame
        }
        if !finishing.isEmpty {
            let cutoff = now().addingTimeInterval(-(Self.finishFlash / .seconds(1)) - 0.2)
            let kept = finishing.filter { $0.value > cutoff }
            if kept.count != finishing.count { finishing = kept }
        }
    }

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

    func toggleAll(_ items: [DownloadActivity]) {
        switch DownloadSummary(downloads: items).mark {
        case .downloading: for item in items where !item.isPaused { pause(item.appID) }
        case .paused: for item in items { resume(item.appID) }
        case .failed: break
        }
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

    // Console sessions share the slot: "Playing on RetroArch", and Quit goes to RetroArch
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
        case .steam(let appID):
            let processes = processes, tracked = tracked
            let folder = reader.files.installFolder(appID: appID)
            let quit = await Task.detached { processes.quit(appID: appID, tracked: tracked, installFolder: folder) }.value
            if quit > 0 { steamGame = nil }
        }
    }
}
