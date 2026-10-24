
import AppKit
import Foundation
import InstallerKit
import UniformTypeIdentifiers

enum GameAction: Hashable, Sendable {
    case play
    case stopGame
    case install
    case toggleFavorite
    case getInfo
    // wineserver -k on the game's own prefix: the leftover session a busy menu labels
    case endSession
    // The local game's own name, in place
    case rename
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
    // The program an installer game starts with: one from its folder, or a file picked in it
    case startsWith(String)
    case chooseExe
    // Wine Tools, on the game's own prefix
    case wineTool(WineTool)
    case winetricks
    case runInPrefix
    case openDriveC
    case showLog
    case showLaunchLogs
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
                      installs: InstallCenter? = nil, consoles: ConsoleCenter? = nil,
                      activity: ActivityCenter? = nil) -> [GameMenuItem] {
        // Only a real Steam game gets steam:// links; an installer game keeps its own launcher
        let steam = game.steamAppID != nil && game.source == .steam
        let store = game.source.isStore
        let expired = model.isExpired(.source(game.source))
        let launching = steamLaunching(game, activity: activity ?? .shared)
        let busy = launching || (store && stores?.job(for: game.id) != nil)
        let playing = store && (stores?.playing.contains(game.id) ?? false)
        // While the game runs, Play is Stop, with no shortcut so a second ⌘↩ never ends it
        let running = isRunning(game, in: model, stores: stores, installs: installs, activity: activity)
        var items: [GameMenuItem] = [
            !game.installed
                ? GameMenuItem(title: String(localized: "Install"), action: .install, disabled: model.isOffline || expired)
                : running
                    ? GameMenuItem(title: String(localized: "Stop Game"), action: .stopGame)
                    : GameMenuItem(title: launching ? String(localized: "Launching…") : String(localized: "Play"), action: .play, shortcut: play, disabled: busy),
            .divider,
        ]
        items.append(contentsOf: [
            GameMenuItem(title: model.isFavorite(game.id) ? String(localized: "Remove from Favorites")
                                                           : String(localized: "Add to Favorites"),
                         action: .toggleFavorite, shortcut: favorite),
            GameMenuItem(title: String(localized: "Get Info"), action: .getInfo, shortcut: getInfo),
        ])
        // A local game's own name: a record written before identification keeps the folder's.
        if game.source == .installer && game.installed {
            items.append(GameMenuItem(title: String(localized: "Rename…"), action: .rename))
        }
        items.append(.divider)
        if game.source == .installer && game.installed {
            items.append(startsWith(game, in: model, installs: installs ?? .shared))
        }
        if !game.source.isConsole && game.installed {
            let runners = game.source == .installer ? model.installRunners : model.steamRunners
            let resolved = model.resolution(for: game).setup
            let windows = resolved.version == .windows
            items.append(GameMenuItem(
                title: String(localized: "Runner"),
                disabled: running || launching || runners.isEmpty || !windows,
                children: runners.map {
                    GameMenuItem(title: "\($0.name) \($0.displayVersion)", action: .runner($0.id),
                                 checked: resolved.runner?.id == $0.id)
                }))
            let backends = model.graphicsChoices(for: game)
            var graphics = backends.map {
                GameMenuItem(title: $0.label, action: .graphics($0), checked: resolved.backend == $0)
            }
            if backends.count < GraphicsBackend.allCases.count {
                if !graphics.isEmpty { graphics.append(.divider) }
                graphics.append(GameMenuItem(title: String(localized: "Get More Graphics Backends…"), action: .moreBackends))
            }
            items.append(GameMenuItem(
                title: String(localized: "Graphics"),
                disabled: running || launching || resolved.runner == nil || !windows,
                children: graphics))
            if let tools = wineTools(for: game, in: model, stores: stores, running: running || launching) {
                items.append(tools)
            }
            items.append(.divider)
        }
        items.append(GameMenuItem(title: String(localized: "Show in Finder"), action: .showInFinder,
                                  disabled: !game.installed))
        if steam {
            items.append(GameMenuItem(title: String(localized: "Show Launch Logs…"), action: .showLaunchLogs))
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
        if game.source.isConsole {
            items.append(GameMenuItem(title: String(localized: "Choose an Image…"), action: .changeCover))
        } else {
            items.append(GameMenuItem(title: String(localized: "Change Cover…"), children: [
                GameMenuItem(title: String(localized: "Search Steam…"), action: .searchCover),
                GameMenuItem(title: String(localized: "Choose an Image…"), action: .changeCover),
            ]))
        }
        if model.coverOverride(for: game.id) != nil {
            items.append(GameMenuItem(title: String(localized: "Use the Original Cover"), action: .resetCover))
        }
        if game.installed, let folder = GameFolder.of(game, in: model.installsFolder) {
            // An in-place import keeps its files: the menu only removes Cartouche's prefix and record.
            // isBusy reads the cached probe answers; building a menu never runs one.
            let center = installs ?? .shared
            items.append(.divider)
            if center.busyGames.contains(game.id) {
                // The label names what actually holds the prefix: the game, a store
                // client or another program — only Wine's helpers leaves a session to end.
                let title: String
                switch center.busyClients[game.id] {
                case .store(let name)?, .program(let name)?:
                    title = String(localized: "Quit \(name)")
                case .game?:
                    title = String(localized: "Quit \(game.name)")
                case .unknown?, nil:
                    title = String(localized: "End Wine Session")
                }
                items.append(GameMenuItem(title: title, action: .endSession))
            }
            items.append(GameMenuItem(
                title: GameUninstall.itemTitle(inPlace: GameUninstall.inPlace(folder)),
                action: .uninstall,
                disabled: center.isBusy(game),
                destructive: true))
        }
        if let consoleGame = game.console, let consoles {
            // A ROM in the user's own folders stays; only a copy inside Cartouche's folder moves to the Trash.
            items.append(.divider)
            items.append(GameMenuItem(
                title: ConsoleUninstall.itemTitle(ownsROM: consoles.ownedROMs.contains(consoleGame.id)),
                action: .uninstall,
                disabled: consoles.isPlaying(game.id),
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

    // A store game Cartouche started, an installer game whose launcher or own process runs,
    // or the Steam game the activity monitor reads as running.
    static func isRunning(_ game: Game, in model: LibraryModel, stores: StoreCenter? = nil,
                          installs: InstallCenter? = nil, activity: ActivityCenter? = nil) -> Bool {
        switch game.source {
        case .installer: game.installed && (installs ?? .shared).isPlaying(game)
        case .steam: steamRunning(game, in: model, activity: activity ?? .shared)
        default: game.source.isStore && (stores?.playing.contains(game.id) ?? false)
        }
    }

    // Steam's running game as the monitor reads it off the main actor; only a game run
    // through Wine has a prefix that Stop can end.
    static func steamLaunching(_ game: Game, activity: ActivityCenter) -> Bool {
        guard game.source == .steam, let id = game.steamAppID else { return false }
        return activity.steamLaunching.contains(id)
    }

    static func steamRunning(_ game: Game, in model: LibraryModel, activity: ActivityCenter) -> Bool {
        guard game.installed, game.source == .steam, let id = game.steamAppID,
              activity.steamGame?.target == .steam(appID: id) else { return false }
        return true
    }

    // Tools that write to the prefix wait while the game runs; the C: drive and the log stay open.
    static func wineTools(for game: Game, in model: LibraryModel, stores: StoreCenter?, running: Bool) -> GameMenuItem? {
        guard let target = GameWineTarget(game, in: model, stores: stores) else { return nil }
        let busy = running || (game.source.isStore && stores?.job(for: game.id) != nil)
        return GameMenuItem(title: String(localized: "Wine Tools"),
                            children: wineToolItems(hasWine: target.hasWine, busy: busy))
    }

    static func wineToolItems(hasWine: Bool, busy: Bool) -> [GameMenuItem] {
        var items: [GameMenuItem] = []
        if hasWine {
            items = [
                GameMenuItem(title: WineTool.winecfg.label, action: .wineTool(.winecfg), disabled: busy),
                GameMenuItem(title: WineTool.regedit.label, action: .wineTool(.regedit), disabled: busy),
                GameMenuItem(title: String(localized: "Winetricks…"), action: .winetricks, disabled: busy),
                GameMenuItem(title: String(localized: "Run Program in Prefix…"), action: .runInPrefix, disabled: busy),
                .divider,
            ]
        }
        return items + [
            GameMenuItem(title: String(localized: "Open C: Drive"), action: .openDriveC),
            GameMenuItem(title: String(localized: "Show Log"), action: .showLog),
        ]
    }

    // The folder's programs as the install sheet ranks them, launchers marked, then a file picked in the folder.
    static func startsWith(_ game: Game, in model: LibraryModel, installs: InstallCenter) -> GameMenuItem {
        var children = model.exeChoices(for: game).map { choice in
            GameMenuItem(title: choice.isLauncher ? String(localized: "\(choice.name) (Launcher)") : choice.name,
                         action: .startsWith(choice.path),
                         checked: GameExecutable.isCurrent(choice, game.executable))
        }
        if !children.isEmpty { children.append(.divider) }
        children.append(GameMenuItem(title: String(localized: "Choose Another…"), action: .chooseExe))
        return GameMenuItem(title: String(localized: "Starts With"),
                            disabled: !model.canChangeExe(game, installs: installs),
                            children: children)
    }
}

// Steam handles launches, verification and removal. Installations start in Cartouche.
@MainActor
struct GameActionRunner {

    var model: LibraryModel
    var installs: InstallCenter = .shared
    var open: @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }
    var reveal: @MainActor (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
    var chooseImage: @MainActor () -> URL? = GameActionRunner.chooseImage
    // Opens the Steam-search cover sheet for the game
    var searchCover: @MainActor (Game) -> Void = { _ in }
    var showInfo: @MainActor () -> Void = {}
    var afterLaunch: @MainActor () -> Void = {}
    var playConsole: @MainActor (Game) -> Void = { _ in }
    var removeConsole: @MainActor (Game) -> Void = { _ in }
    // DXMT's winemetal.dll is refreshed first, as store games do at launch; returns the failure text, nil on success.
    var playInstaller: @MainActor (Game, URL, InstallCenter) -> String? = { game, installs, center in
        if case .failure(let error) = GameActionRunner.launchInstaller(game, installs: installs, center: center) {
            return error.errorDescription
        }
        return nil
    }
    // The rename sheet's answer: the new name, or nil on cancel or an empty one.
    var renamePrompt: @MainActor (Game) -> String? = GameActionRunner.renamePrompt
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
    // The open panel for Choose Another…, starting in the game's folder; nil on cancel.
    var chooseExe: @MainActor (Game, URL) -> URL? = GameActionRunner.chooseExe
    // Reads which Steam game runs, for Stop and the Wine Tools that wait for it
    var activity: ActivityCenter = .shared
    // Run Program in Prefix… and Winetricks… ask first; nil on cancel.
    var chooseProgram: @MainActor (WinePrefix) -> URL? = PrefixTools.chooseProgram
    var winetricksPrompt: @MainActor (Game) -> String? = GameActionRunner.winetricksPrompt
    // The prefix work itself, run off the main actor
    var launchTool: @Sendable (WineTool, PrefixWine) throws -> Void = { try PrefixTools.launch($0, with: $1) }
    var runProgram: @Sendable (URL, PrefixWine, String) throws -> Void = { try PrefixTools.run($0, with: $1, step: $2) }
    var runWinetricks: @Sendable ([String], WinePrefix, PrefixWine) async throws -> URL = {
        try await PrefixTools.winetricks($0, in: $1, wine: $2)
    }
    var stopSteamGame: @Sendable (Int, SteamLocalFiles) -> SteamGameStop.Outcome = {
        SteamGameStop(files: $1).stop(appID: $0)
    }

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
        if action == .install && !game.installed && (game.source == .steam || game.source.isStore) {
            model.installRequest = game
            return
        }
        if game.source.isStore, let stores, performStore(action, on: game, stores) { return }
        switch action {
        case .play:
            if game.source == .installer {
                // A second Play while its launcher still runs would start the game twice
                guard !installs.playingGames.contains(game.id) else { return }
                if let failure = playInstaller(game, model.installsFolder, installs) {
                    model.problem = failure
                } else {
                    afterLaunch()
                    // wineserver takes a moment to show, so the probe waits a bit
                    installs.refreshBusy(for: [game], in: model.installsFolder, after: .seconds(2))
                }
            } else if let id = game.steamAppID {
                guard !GameMenu.steamLaunching(game, activity: activity), !GameMenu.steamRunning(game, in: model, activity: activity) else { return }
                let setup = model.resolution(for: game).setup
                AppLog.note("Steam launch requested app=\(id) runner=\(setup.runner?.id ?? "native") graphics=\(setup.backend?.rawValue ?? "native")")
                open(URL(string: "steam://rungameid/\(id)")!)
                Task { await activity.refresh() }
                afterLaunch()
            } else if game.console != nil {
                playConsole(game)
            }
        case .install:
            break
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
                let files = model.importer.files, model = model, open = open
                Task {
                    let plan = await Task.detached { SteamGameRemoval.plan(appID: id, files: files) }.value
                    SteamInstallCenter.shared.clear(appID: id)
                    open(URL(string: "steam://uninstall/\(id)")!)
                    guard let plan else { return }
                    do {
                        if try await SteamGameRemoval.finish(plan) {
                            await model.load()
                            model.didUninstallSteam(appID: id)
                        }
                    } catch { model.problem = error.localizedDescription }
                }
            } else if game.console != nil {
                removeConsole(game)
            }
        case .endSession:
            installs.endSession(for: game, in: model.installsFolder)
        case .stopGame:
            if game.source == .installer {
                installs.stopGame(game, in: model.installsFolder)
            } else if game.source == .steam, let id = game.steamAppID {
                stopSteam(game, appID: id)
            }
        case .rename:
            if let name = renamePrompt(game) { model.rename(game, to: name) }
        case .moreBackends:
            moreBackends()
        case .startsWith(let path):
            changeExe(of: game, to: URL(filePath: path))
        case .chooseExe:
            if let folder = model.exeFolder(for: game), let exe = chooseExe(game, folder) {
                changeExe(of: game, to: exe)
            }
        case .update:
            break
        case .wineTool(let tool):
            guard !isRunning(game) else { return }
            let launch = launchTool
            withPrefix(of: game) { prefix, target in
                offMain { try launch(tool, target.wine(for: prefix, step: String(localized: "Open \(tool.label)"))) }
            }
        case .runInPrefix:
            guard !isRunning(game) else { return }
            let run = runProgram, choose = chooseProgram
            withPrefix(of: game) { prefix, target in
                guard let program = choose(prefix) else { return }
                let step = String(localized: "Run \(program.lastPathComponent)")
                offMain { try run(program, target.wine(for: prefix, step: step), step) }
            }
        case .winetricks:
            guard !isRunning(game) else { return }
            let tricks = runWinetricks, ask = winetricksPrompt, model = model
            withPrefix(of: game) { prefix, target in
                guard let text = ask(game) else { return }
                let verbs = PrefixTools.winetricksVerbs(text)
                Task {
                    do {
                        _ = try await Task.detached {
                            try await tricks(verbs, prefix, target.wine(for: prefix, step: String(localized: "Run Winetricks")))
                        }.value
                    } catch {
                        model.problem = error.localizedDescription
                    }
                }
            }
        case .openDriveC:
            let open = open
            withPrefix(of: game) { prefix, _ in open(PrefixTools.driveC(of: prefix)) }
        case .showLaunchLogs:
            let open = open, model = model
            withPrefix(of: game) { prefix, _ in
                let folder = prefix.root.appending(path: "cartouche-logs")
                if FileManager.default.fileExists(atPath: folder.path) {
                    open(folder)
                } else {
                    model.problem = String(localized: "\(game.name) has no launch logs yet.")
                }
            }
        case .showLog:
            let open = open, model = model
            withPrefix(of: game) { prefix, _ in
                Task {
                    if let log = await Task.detached(operation: { PrefixLog.latest(for: prefix) }).value {
                        open(log)
                    } else {
                        model.problem = String(localized: "\(game.name) has no log yet.")
                    }
                }
            }
        }
    }

    private func isRunning(_ game: Game) -> Bool {
        GameMenu.isRunning(game, in: model, stores: stores, installs: installs, activity: activity)
    }

    // The game's own prefix, found off the main actor; a game not played yet has none.
    private func withPrefix(of game: Game, _ body: @escaping @MainActor (WinePrefix, GameWineTarget) -> Void) {
        guard let target = GameWineTarget(game, in: model, stores: stores) else { return }
        let files = model.importer.files, model = model
        Task {
            guard let prefix = await Task.detached(operation: { target.prefix(files: files) }).value else {
                model.problem = String(localized: "\(game.name) has no Windows prefix yet. Play it once first.")
                return
            }
            body(prefix, target)
        }
    }

    private func offMain(_ work: @escaping @Sendable () throws -> Void) {
        let model = model
        Task {
            do {
                try await Task.detached(operation: work).value
            } catch {
                model.problem = error.localizedDescription
            }
        }
    }

    // Stop ends the Wine processes of the game's own compatdata prefix, never Steam itself.
    private func stopSteam(_ game: Game, appID: Int) {
        if model.resolution(for: game).setup.version == .mac {
            Task { await activity.quitSteamGame(appID) }
            return
        }
        let stop = stopSteamGame, files = model.importer.files, model = model, activity = activity
        Task {
            let outcome = await Task.detached { stop(appID, files) }.value
            switch outcome {
            case .noPrefix:
                model.problem = String(localized: "Cartouche couldn’t find \(game.name)’s Windows prefix, so it can’t stop the game.")
            case .unknown:
                model.problem = String(localized: "Cartouche couldn’t tell which processes belong to \(game.name), so it stopped nothing.")
            case .notRunning, .stopped:
                break
            }
            await activity.refresh()
        }
    }

    private func changeExe(of game: Game, to exe: URL) {
        let path = exe.standardizedFileURL.path(percentEncoded: false)
        guard game.executable?.standardizedFileURL.path(percentEncoded: false) != path else { return }
        let model = model, installs = installs
        Task { await model.changeExe(of: game, to: exe, installs: installs) }
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

    static func chooseExe(_ game: Game, in folder: URL) -> URL? {
        let panel = NSOpenPanel()
        panel.directoryURL = folder
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = UTType(filenameExtension: "exe").map { [$0] } ?? []
        panel.message = String(localized: "Choose the program \(game.name) starts with, inside its folder.")
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func renamePrompt(_ game: Game) -> String? {
        let alert = NSAlert()
        alert.messageText = String(localized: "Rename \(game.name)")
        alert.informativeText = String(localized: "The name shows in the library; the game’s files keep their folder’s name.")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = game.name
        field.placeholderString = String(localized: "Game name")
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "Rename"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty || name == game.name ? nil : name
    }

    static func winetricksPrompt(_ game: Game) -> String? {
        let alert = NSAlert()
        alert.messageText = "Winetricks"
        alert.informativeText = String(localized: "Enter the Winetricks verbs to install in \(game.name), separated by spaces.")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "vcrun2022 corefonts"
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "Install"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn,
              !PrefixTools.winetricksVerbs(field.stringValue).isEmpty else { return nil }
        return field.stringValue
    }

    @discardableResult
    @MainActor static func launchInstaller(
        _ game: Game, installs: URL = GameFolder.installs, center: InstallCenter = .shared
    ) -> Result<Void, LaunchFailed> {
        guard game.id.hasPrefix("installer:") else { return .success(()) }
        let folder = GameFolder(root: installs.appending(path: String(game.id.dropFirst("installer:".count))))
        guard let record = InstalledGames.record(in: folder) else {
            return .failure(LaunchFailed(String(localized: "Cartouche couldn’t read this install’s record.")))
        }
        guard FileManager.default.fileExists(atPath: record.launcher.path(percentEncoded: false)) else {
            return .failure(LaunchFailed(String(localized: "Cartouche couldn’t find \(game.name)’s launcher.")))
        }
        SetupEnvironment.prepare(record.backend, prefix: folder.prefix, backends: BackendInstaller.folder)
        // An older launcher learns to keep Wine's crash dialog away; a refused write still launches.
        try? CrashHandling.addLauncherLines(to: folder)
        try? GameLauncher.addFrameCounter(to: folder)
        let performance: LocalPerformanceSession?
        do {
            performance = try LocalPerformanceSession.begin(
                appID: game.steamAppID ?? game.compatAppID ?? record.appID, record: record,
                launcher: (try? String(contentsOf: folder.launcher, encoding: .utf8)) ?? "")
        } catch {
            AppLog.note("local FPS session could not be created: \(error.localizedDescription)")
            performance = nil
        }
        // The run is kept so the session's leftovers can be waited out once the game exits;
        // its output, a crash's backtrace included, goes to the game's log through a plain file
        // handle, which outlives Cartouche where a pipe would leave the game writing to nothing.
        let run = InstallRun(InstallLaunch(
            executable: "/bin/sh",
            arguments: [record.launcher.path(percentEncoded: false)],
            environment: [
                "HOME": NSHomeDirectory(),
                "USER": NSUserName(),
                "TMPDIR": NSTemporaryDirectory(),
                "LANG": ProcessInfo.processInfo.environment["LANG"] ?? "en_US.UTF-8",
                "PATH": "/usr/bin:/bin",
            ].merging(performance?.environment ?? [:], uniquingKeysWith: { _, value in value })), output: folder.gameLog)
        do {
            try run.start()
            center.watchSession(run, for: game, in: installs, performance: performance)
            return .success(())
        } catch {
            performance?.finish()
            return .failure(LaunchFailed(String(localized: "Cartouche couldn’t start \(game.name): \(error.localizedDescription)")))
        }
    }
}

struct LaunchFailed: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
