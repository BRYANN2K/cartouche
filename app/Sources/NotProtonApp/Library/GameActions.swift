
import AppKit
import Foundation

enum GameAction: Hashable, Sendable {
    case play
    case stopGame
    case install
    case toggleFavorite
    case getInfo
    case runner(String)
    case graphics(GraphicsBackend)
    case showInFinder
    case showInSteam
    case verifyFiles
    case update
    case changeCover
    case searchCover
    case resetCover
    case hide
    case unhide
    case uninstall
    case moreBackends
}

struct Shortcut: Equatable, Sendable {
    let key: String
    let command: Bool
    var label: String { (command ? "⌘" : "") + (key == "\r" ? "↩" : key.uppercased()) }
}

struct GameMenuItem: Equatable {
    let title: String
    var action: GameAction?
    var shortcut: Shortcut?
    var checked = false
    var disabled = false
    var destructive = false
    var children: [GameMenuItem] = []
    var isDivider: Bool { title.isEmpty && action == nil && children.isEmpty }

    static let divider = GameMenuItem(title: "")
}

@MainActor
enum GameMenu {

    static let play = Shortcut(key: "\r", command: true)
    static let favorite = Shortcut(key: "d", command: true)
    static let getInfo = Shortcut(key: "i", command: true)

    static func items(for game: Game, in model: LibraryModel, stores: StoreCenter? = nil,
                      installs: InstallCenter? = nil) -> [GameMenuItem] {
        let setup = model.setup(for: game.id)
        // Only a real Steam game gets steam:// links; an installer game keeps its own launcher
        let steam = game.steamAppID != nil && game.source == .steam
        let store = game.source.isStore
        let expired = model.isExpired(.source(game.source))
        let busy = store && stores?.job(for: game.id) != nil
        let playing = store && (stores?.playing.contains(game.id) ?? false)
        var items: [GameMenuItem] = [
            game.installed
                ? GameMenuItem(title: String(localized: "Play"), action: .play, shortcut: play, disabled: busy || playing)
                : GameMenuItem(title: String(localized: "Install"), action: .install, disabled: model.isOffline || expired),
            .divider,
        ]
        if playing {
            items.append(GameMenuItem(title: String(localized: "Stop Game"), action: .stopGame))
            items.append(.divider)
        }
        items.append(contentsOf: [
            GameMenuItem(title: model.isFavorite(game.id) ? String(localized: "Remove from Favorites")
                                                           : String(localized: "Add to Favorites"),
                         action: .toggleFavorite, shortcut: favorite),
            GameMenuItem(title: String(localized: "Get Info"), action: .getInfo, shortcut: getInfo),
            .divider,
        ])
        if !game.source.isConsole {
            let runners = game.source == .installer ? model.installRunners : model.runners.filter(\.isOffered)
            let resolved = model.resolution(for: game).setup
            let windows = resolved.version == .windows
            items.append(GameMenuItem(
                title: String(localized: "Runner"),
                disabled: runners.isEmpty || !windows,
                children: runners.map {
                    GameMenuItem(title: "\($0.kind.name) \($0.displayVersion)", action: .runner($0.id),
                                 checked: resolved.runner?.id == $0.id)
                }))
            var graphics: [GameMenuItem] = (resolved.runner == nil ? GraphicsBackend.allCases : model.graphicsChoices(for: game)).map {
                GameMenuItem(title: $0.label, action: .graphics($0), checked: (resolved.backend ?? setup.graphics) == $0)
            }
            // A backend that cannot run names what it is missing instead of just disappearing.
            if let runner = resolved.runner {
                graphics += GraphicsBackend.allCases.compactMap { backend in
                    BackendSupport.missing(backend, for: runner, translation: resolved.translation,
                                           availability: model.backendAvailability)
                        .map { GameMenuItem(title: "\(backend.label) — \($0)", disabled: true) }
                }
                graphics.append(.divider)
                graphics.append(GameMenuItem(title: String(localized: "Get More Graphics Backends…"), action: .moreBackends))
            }
            items.append(GameMenuItem(
                title: String(localized: "Graphics"),
                disabled: resolved.runner == nil || !windows,
                children: graphics))
            items.append(.divider)
        }
        items.append(GameMenuItem(title: String(localized: "Show in Finder"), action: .showInFinder,
                                  disabled: !game.installed))
        if steam {
            items.append(GameMenuItem(title: String(localized: "Show in Steam"), action: .showInSteam))
            items.append(GameMenuItem(title: String(localized: "Verify Files"), action: .verifyFiles, disabled: !game.installed))
        }
        if game.source == .installer && game.installed {
            items.append(GameMenuItem(title: String(localized: "Verify Files…"), action: .verifyFiles))
        }
        if store && game.installed {
            let online = !model.isOffline && !expired && !busy
            items.append(GameMenuItem(title: String(localized: "Check for Update"), action: .update, disabled: !online))
            items.append(GameMenuItem(title: String(localized: "Verify Files"), action: .verifyFiles, disabled: !online))
        }
        items.append(GameMenuItem(title: String(localized: "Change Cover…"), children: [
            GameMenuItem(title: String(localized: "Search Steam…"), action: .searchCover),
            GameMenuItem(title: String(localized: "Choose an Image…"), action: .changeCover),
        ]))
        if model.coverOverride(for: game.id) != nil {
            items.append(GameMenuItem(title: String(localized: "Use the Original Cover"), action: .resetCover))
        }
        if game.installed, let folder = GameFolder.of(game, in: model.installsFolder) {
            // An in-place import keeps its files: the menu only removes Cartouche's prefix and record.
            // isBusy reads the cached probe answers; building a menu never runs one.
            items.append(.divider)
            items.append(GameMenuItem(
                title: GameUninstall.itemTitle(inPlace: GameUninstall.inPlace(folder)),
                action: .uninstall,
                disabled: (installs ?? .shared).isBusy(game),
                destructive: true))
        }
        items.append(.divider)
        items.append(model.isHidden(game.id)
            ? GameMenuItem(title: String(localized: "Show Game"), action: .unhide)
            : GameMenuItem(title: String(localized: "Hide Game"), action: .hide))
        if steam || store {
            items.append(GameMenuItem(title: String(localized: "Uninstall…"), action: .uninstall,
                                      disabled: !game.installed || busy || playing, destructive: true))
        }
        return items
    }
}

// Steam games go through steam:// links, so Steam does the installing, verifying and uninstalling.
@MainActor
struct GameActionRunner {

    var model: LibraryModel
    var open: @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }
    var reveal: @MainActor (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
    var chooseImage: @MainActor () -> URL? = GameActionRunner.chooseImage
    // Opens the Steam-search cover sheet for the game
    var searchCover: @MainActor (Game) -> Void = { _ in }
    var showInfo: @MainActor () -> Void = {}
    var afterLaunch: @MainActor () -> Void = {}
    var playConsole: @MainActor (Game) -> Void = { _ in }
    // DXMT's winemetal.dll is refreshed first, as store games do at launch; returns the failure text, nil on success.
    var playInstaller: @MainActor (Game) -> String? = { game in
        if case .failure(let error) = GameActionRunner.launchInstaller(game) { return error.errorDescription }
        return nil
    }
    var stores: StoreCenter?
    var confirmUninstall: @MainActor (Game) -> Bool = GameActionRunner.confirmUninstall
    // Where a missing backend is fixed: Settings > Compatibility, with its Runners and downloads.
    var moreBackends: @MainActor () -> Void = {
        UserDefaults.standard.set(SettingsTab.compatibility.rawValue, forKey: SettingsWindow.tabKey)
        NSApp.activate()
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
    var uninstall = GameUninstall()
    var confirmRemoval: @MainActor (RemovalPlan) -> RemovalAnswer = GameUninstall.confirm

    static func confirmUninstall(_ game: Game) -> Bool {
        let alert = NSAlert()
        alert.messageText = String(localized: "Uninstall \(game.name)?")
        alert.informativeText = String(localized: "Its files and its prefix are deleted. Cloud saves stay with the store.")
        alert.addButton(withTitle: String(localized: "Uninstall"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.buttons.first?.hasDestructiveAction = true
        return alert.runModal() == .alertFirstButtonReturn
    }

    func perform(_ action: GameAction, on game: Game) {
        if game.source.isStore, let stores, performStore(action, on: game, stores) { return }
        switch action {
        case .play:
            if game.source == .installer {
                if let failure = playInstaller(game) {
                    model.problem = failure
                } else {
                    afterLaunch()
                    // wineserver takes a moment to show, so the probe waits a bit
                    InstallCenter.shared.refreshBusy(for: [game], in: model.installsFolder, after: .seconds(2))
                }
            } else if let id = game.steamAppID {
                open(URL(string: "steam://rungameid/\(id)")!)
                afterLaunch()
            } else if game.console != nil {
                playConsole(game)
            }
        case .install:
            if let id = game.steamAppID { open(URL(string: "steam://install/\(id)")!) }
        case .toggleFavorite:
            model.toggleFavorite(game.id)
        case .getInfo:
            model.select(game.id)
            showInfo()
        case .runner(let id):
            var setup = model.setup(for: game.id)
            setup.runnerID = id
            model.setSetup(setup, for: game.id)
        case .graphics(let backend):
            var setup = model.setup(for: game.id)
            setup.graphics = backend
            model.setSetup(setup, for: game.id)
        case .showInFinder:
            if let file = game.console?.fileURL {
                reveal(file)
            } else if let folder = model.installFolder(of: game) {
                reveal(folder)
            }
        case .showInSteam:
            if let id = game.steamAppID { open(URL(string: "steam://nav/games/details/\(id)")!) }
        case .verifyFiles:
            if game.source == .installer {
                model.verificationRequest = game
            } else if let id = game.steamAppID {
                open(URL(string: "steam://validate/\(id)")!)
            }
        case .changeCover:
            if let image = chooseImage() { model.setCover(image, for: game.id) }
        case .searchCover:
            searchCover(game)
        case .resetCover:
            model.clearCover(for: game.id)
        case .hide:
            model.hide(game.id)
        case .unhide:
            model.unhide(game.id)
        case .uninstall:
            if game.source == .installer {
                removeInstalled(game)
            } else if let id = game.steamAppID {
                open(URL(string: "steam://uninstall/\(id)")!)
            }
        case .moreBackends:
            moreBackends()
        case .update, .stopGame:
            break
        }
    }

    private func removeInstalled(_ game: Game) {
        let uninstall = uninstall
        let installsFolder = model.installsFolder
        // The real check happens here, fresh: lsof and the folder walk run off the main
        // actor, then the confirmation and the model updates come back to it.
        Task {
            guard let plan = await Task.detached(operation: {
                uninstall.plan(for: game, installs: installsFolder)
            }).value,
                  !plan.busy else { return }
            guard case .moveToTrash(let keepSaves) = confirmRemoval(plan) else { return }
            do {
                try uninstall.remove(plan, keepSaves: keepSaves)
                model.clearCover(for: game.id)
                model.showInstalledGames(InstalledGames.all(in: installsFolder))
            } catch {
                model.problem = String(localized: "Cartouche couldn’t remove \(game.name): \(error.localizedDescription)")
            }
        }
    }

    private func performStore(_ action: GameAction, on game: Game, _ stores: StoreCenter) -> Bool {
        switch action {
        case .play: stores.play(game)
        case .stopGame: stores.stopPlaying(game)
        case .install: stores.install(game)
        case .update: stores.update(game)
        case .verifyFiles: stores.verify(game)
        case .uninstall:
            if confirmUninstall(game) { Task { await stores.uninstall(game) } }
        case .showInFinder:
            if let record = stores.record(game.id) { reveal(record.install.path) }
        default: return false
        }
        return true
    }

    static func chooseImage() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = String(localized: "Choose a cover image.")
        return panel.runModal() == .OK ? panel.url : nil
    }

    @discardableResult
    @MainActor static func launchInstaller(_ game: Game, installs: URL = GameFolder.installs) -> Result<Void, LaunchFailed> {
        guard game.id.hasPrefix("installer:") else { return .success(()) }
        let folder = GameFolder(root: installs.appending(path: String(game.id.dropFirst("installer:".count))))
        guard let record = InstalledGames.record(in: folder) else {
            return .failure(LaunchFailed(String(localized: "Cartouche couldn’t read this install’s record.")))
        }
        guard FileManager.default.fileExists(atPath: record.launcher.path(percentEncoded: false)) else {
            return .failure(LaunchFailed(String(localized: "Cartouche couldn’t find \(game.name)’s launcher.")))
        }
        SetupEnvironment.prepare(record.backend, prefix: folder.prefix, backends: BackendInstaller.folder)
        do {
            try Shell.detach("/bin/sh", [record.launcher.path(percentEncoded: false)], environment: [
                "HOME": NSHomeDirectory(),
                "USER": NSUserName(),
                "TMPDIR": NSTemporaryDirectory(),
                "LANG": ProcessInfo.processInfo.environment["LANG"] ?? "en_US.UTF-8",
                "PATH": "/usr/bin:/bin",
            ])
            return .success(())
        } catch {
            return .failure(LaunchFailed(String(localized: "Cartouche couldn’t start \(game.name): \(error.localizedDescription)")))
        }
    }
}

struct LaunchFailed: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
