
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
    case resetCover
    case hide
    case unhide
    case uninstall
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

    static func items(for game: Game, in model: LibraryModel, stores: StoreCenter? = nil) -> [GameMenuItem] {
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
            let backends = resolved.runner == nil ? GraphicsBackend.allCases : model.graphicsChoices(for: game)
            items.append(GameMenuItem(
                title: String(localized: "Graphics"),
                disabled: resolved.runner == nil || !windows,
                children: backends.map {
                    GameMenuItem(title: $0.label, action: .graphics($0), checked: (resolved.backend ?? setup.graphics) == $0)
                }))
            items.append(.divider)
        }
        items.append(GameMenuItem(title: String(localized: "Show in Finder"), action: .showInFinder,
                                  disabled: !game.installed))
        if steam {
            items.append(GameMenuItem(title: String(localized: "Show in Steam"), action: .showInSteam))
            items.append(GameMenuItem(title: String(localized: "Verify Files"), action: .verifyFiles, disabled: !game.installed))
        }
        if store && game.installed {
            let online = !model.isOffline && !expired && !busy
            items.append(GameMenuItem(title: String(localized: "Check for Update"), action: .update, disabled: !online))
            items.append(GameMenuItem(title: String(localized: "Verify Files"), action: .verifyFiles, disabled: !online))
        }
        items.append(GameMenuItem(title: String(localized: "Change Cover…"), action: .changeCover))
        if model.coverOverride(for: game.id) != nil {
            items.append(GameMenuItem(title: String(localized: "Use the Original Cover"), action: .resetCover))
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
            if let id = game.steamAppID { open(URL(string: "steam://validate/\(id)")!) }
        case .changeCover:
            if let image = chooseImage() { model.setCover(image, for: game.id) }
        case .resetCover:
            model.clearCover(for: game.id)
        case .hide:
            model.hide(game.id)
        case .unhide:
            model.unhide(game.id)
        case .uninstall:
            if let id = game.steamAppID { open(URL(string: "steam://uninstall/\(id)")!) }
        case .update, .stopGame:
            break
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
