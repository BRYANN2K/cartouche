
import Foundation

// The prefix a game's Wine Tools act on: an installer game's folder, a store game's record folder
// or a Steam game's compatdata. Built on the main actor from in-memory state only; the prefix
// and its Wine are looked up off it.
struct GameWineTarget: Sendable {

    enum Kind: Equatable, Sendable {
        case installer(URL)
        case store(GameSource, URL)
        case steam(Int)
    }

    let kind: Kind
    let name: String
    // A store game's Wine is its setup's runner
    var runner: Runner? = nil

    @MainActor init?(_ game: Game, in model: LibraryModel, stores: StoreCenter?) {
        guard game.installed else { return nil }
        switch game.source {
        case .installer:
            guard let folder = GameFolder.of(game, in: model.installsFolder) else { return nil }
            kind = .installer(folder.root)
        case .steam:
            // A Mac build runs without Wine, so it has no prefix to open
            guard let id = game.steamAppID, model.resolution(for: game).setup.version == .windows else { return nil }
            kind = .steam(id)
        case let source where source.isStore:
            guard let record = stores?.record(game.id) else { return nil }
            kind = .store(source, record.folder)
            runner = model.resolution(for: game).setup.runner
        default:
            return nil
        }
        name = game.name
    }

    // Wine Configuration, Registry Editor, Winetricks and Run Program need the game's Wine
    var hasWine: Bool {
        if case .store = kind { return runner != nil }
        return true
    }

    // nil until the game's prefix exists
    func prefix(files: SteamLocalFiles) -> WinePrefix? {
        let prefix: WinePrefix
        switch kind {
        case .installer(let root):
            prefix = WinePrefix(appID: root.lastPathComponent, name: name,
                                library: SteamLibrary(root: root.deletingLastPathComponent()), lastUsed: nil,
                                source: .installer, folder: root)
        case .store(let source, let folder):
            prefix = WinePrefix(appID: folder.lastPathComponent, name: name,
                                library: SteamLibrary(root: folder.deletingLastPathComponent()), lastUsed: nil,
                                source: .store(source), folder: folder)
        case .steam(let id):
            return files.compatPrefix(appID: id, name: name)
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: prefix.pfx.path(percentEncoded: false), isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return prefix
    }

    func wine(for prefix: WinePrefix, step: String) throws -> PrefixWine {
        guard case .store = kind else { return try PrefixTools.wine(for: prefix, step: step) }
        guard let runner, let wine = InstallRunners.wine(for: runner) else {
            throw StepFailure(step: step, detail: String(localized: "Choose a runner in \(name)’s setup first."))
        }
        return try PrefixTools.wine(for: prefix, runner: wine, step: step)
    }
}
