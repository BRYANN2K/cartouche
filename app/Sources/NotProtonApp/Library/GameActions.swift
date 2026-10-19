// Every action on a game, listed once. The context menu, the Game menu in the menu
// bar and the panel's More button all show this list, so none can miss an action.

import AppKit
import Foundation

enum GameAction: Hashable, Sendable {
    case play
    case install
    case toggleFavorite
    case getInfo
    case runner(String)
    case graphics(GraphicsBackend)
    case showInFinder
    case showInSteam
    case verifyFiles
    case changeCover
    case resetCover
    case hide
    case unhide
    case uninstall
}

struct Shortcut: Equatable, Sendable {
    let key: String
    let command: Bool
    // ⌘↩, ⌘D, ⌘I as menus print them
    var label: String { (command ? "⌘" : "") + (key == "\r" ? "↩" : key.uppercased()) }
}

struct GameMenuItem: Identifiable, Equatable {
    let title: String
    var action: GameAction?
    var shortcut: Shortcut?
    var checked = false
    var disabled = false
    var destructive = false
    var children: [GameMenuItem] = []
    // A separator when both title and action are empty
    var isDivider: Bool { title.isEmpty && action == nil && children.isEmpty }

    var id: String { title.isEmpty ? UUID().uuidString : title + (action.map { "\($0)" } ?? "") }

    static let divider = GameMenuItem(title: "")
}

@MainActor
enum GameMenu {

    static let play = Shortcut(key: "\r", command: true)
    static let favorite = Shortcut(key: "d", command: true)
    static let getInfo = Shortcut(key: "i", command: true)

    static func items(for game: Game, in model: LibraryModel) -> [GameMenuItem] {
        let setup = model.setup(for: game.id)
        let steam = game.steamAppID != nil
        var items: [GameMenuItem] = [
            game.installed
                ? GameMenuItem(title: String(localized: "Play"), action: .play, shortcut: play)
                : GameMenuItem(title: String(localized: "Install"), action: .install, disabled: model.isOffline),
            .divider,
            GameMenuItem(title: model.isFavorite(game.id) ? String(localized: "Remove from Favorites")
                                                           : String(localized: "Add to Favorites"),
                         action: .toggleFavorite, shortcut: favorite),
            GameMenuItem(title: String(localized: "Get Info"), action: .getInfo, shortcut: getInfo),
            .divider,
        ]
        if !game.source.isConsole {
            let runners = model.runners.filter(\.isOffered)
            items.append(GameMenuItem(
                title: String(localized: "Runner"),
                disabled: runners.isEmpty,
                children: runners.map {
                    GameMenuItem(title: "\($0.kind.name) \($0.displayVersion)", action: .runner($0.id),
                                 checked: (setup.runnerID ?? runners.first?.id) == $0.id)
                }))
            items.append(GameMenuItem(
                title: String(localized: "Graphics"),
                children: GraphicsBackend.allCases.map {
                    GameMenuItem(title: $0.label, action: .graphics($0), checked: (setup.graphics ?? .d3dmetal) == $0)
                }))
            items.append(.divider)
        }
        items.append(GameMenuItem(title: String(localized: "Show in Finder"), action: .showInFinder,
                                  disabled: !game.installed))
        if steam {
            items.append(GameMenuItem(title: String(localized: "Show in Steam"), action: .showInSteam))
            items.append(GameMenuItem(title: String(localized: "Verify Files"), action: .verifyFiles, disabled: !game.installed))
        }
        items.append(GameMenuItem(title: String(localized: "Change Cover…"), action: .changeCover))
        if model.coverOverride(for: game.id) != nil {
            items.append(GameMenuItem(title: String(localized: "Use the Original Cover"), action: .resetCover))
        }
        items.append(.divider)
        items.append(model.isHidden(game.id)
            ? GameMenuItem(title: String(localized: "Show Game"), action: .unhide)
            : GameMenuItem(title: String(localized: "Hide Game"), action: .hide))
        if steam {
            items.append(GameMenuItem(title: String(localized: "Uninstall…"), action: .uninstall,
                                      disabled: !game.installed, destructive: true))
        }
        return items
    }

    // Every action an item list can run, children included
    static func actions(_ items: [GameMenuItem]) -> [GameAction] {
        items.flatMap { ($0.action.map { [$0] } ?? []) + actions($0.children) }
    }
}

// Runs a menu action. Steam games go through Steam's own steam:// links, so Steam
// does the installing, verifying and uninstalling.
@MainActor
struct GameActionRunner {

    var model: LibraryModel
    var open: @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }
    var reveal: @MainActor (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
    var chooseImage: @MainActor () -> URL? = GameActionRunner.chooseImage
    // Called for Get Info, so the window shows the panel
    var showInfo: @MainActor () -> Void = {}
    // What Cartouche does once a game starts, from Settings > General
    var afterLaunch: @MainActor () -> Void = {}

    func perform(_ action: GameAction, on game: Game) {
        switch action {
        case .play:
            if let id = game.steamAppID {
                open(URL(string: "steam://rungameid/\(id)")!)
                afterLaunch()
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
            if let folder = model.installFolder(of: game) { reveal(folder) }
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
        }
    }

    static func chooseImage() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = String(localized: "Choose a cover image.")
        return panel.runModal() == .OK ? panel.url : nil
    }
}
