//// Removing an installer game: only its own folder under installs/ ever moves, and only to the Trash.
//// A game imported in place keeps its files where they are; only Cartouche's prefix and record go.

import AppKit
import Foundation

// What the confirmation names: the game, the space the Trash frees, and the saves in the prefix.
struct RemovalPlan: Sendable, Equatable {
    let game: Game
    let folder: GameFolder
    // The game was imported where it is: its files are the user's and never move.
    let inPlace: Bool
    // A live wineserver session on the prefix: the game is running.
    let busy: Bool
    let bytes: Int64
    let hasSaves: Bool

    var title: String { GameUninstall.itemTitle(inPlace: inPlace) }
}

enum RemovalAnswer: Equatable, Sendable {
    case cancel
    case moveToTrash(keepSaves: Bool)
}

struct GameUninstall: Sendable {

    // The folders a Wine game keeps saves in, under drive_c/users/<name>/.
    static let saveDirs = ["AppData", "Saved Games", "Documents/My Games"]

    var trash: @Sendable (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    var saves: URL = SupportPaths.saves
    var measure: @Sendable (URL) -> Int64 = { PrefixStore.directoryBytes($0) }
    var inUse: @Sendable (GameFolder) -> Bool = { PrefixStore.isInUse(root: $0.root, pfx: $0.prefix) }

    static func itemTitle(inPlace: Bool) -> String {
        inPlace ? String(localized: "Remove from Library…") : String(localized: "Uninstall…")
    }

    static func inPlace(_ folder: GameFolder) -> Bool {
        guard let record = InstalledGames.record(in: folder) else { return false }
        return record.gameFolder != nil || record.inferredGameFolder != nil
    }

    func plan(for game: Game, installs: URL = GameFolder.installs) -> RemovalPlan? {
        guard let folder = GameFolder.of(game, in: installs),
              FileManager.default.fileExists(atPath: folder.root.path(percentEncoded: false))
        else { return nil }
        return RemovalPlan(game: game, folder: folder, inPlace: Self.inPlace(folder),
                           busy: inUse(folder), bytes: measure(folder.root),
                           hasSaves: !Self.saveFolders(in: folder.prefix).isEmpty)
    }

    // The saves are copied out first, so a failed copy leaves the whole folder where it was.
    func remove(_ plan: RemovalPlan, keepSaves: Bool) throws {
        if keepSaves { try copySaves(plan) }
        try trash(plan.folder.root)
    }

    private func copySaves(_ plan: RemovalPlan) throws {
        let fm = FileManager.default
        for (dir, relative) in Self.saveFolders(in: plan.folder.prefix) {
            let target = saves.appending(path: plan.folder.root.lastPathComponent).appending(path: relative)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: dir, to: target)
        }
    }

    // drive_c/users/<name>/<save dir> pairs holding at least one file, with the path to keep them under.
    static func saveFolders(in prefix: URL) -> [(dir: URL, relative: String)] {
        let fm = FileManager.default
        let users = prefix.appending(path: "drive_c/users")
        let names = (try? fm.contentsOfDirectory(atPath: users.path(percentEncoded: false))) ?? []
        var found: [(URL, String)] = []
        for name in names.sorted() where !name.hasPrefix(".") {
            let user = users.appending(path: name)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: user.path(percentEncoded: false), isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            for relative in saveDirs {
                let dir = user.appending(path: relative)
                if holdsFiles(dir) { found.append((dir, "\(name)/\(relative)")) }
            }
        }
        return found
    }

    private static func holdsFiles(_ dir: URL) -> Bool {
        guard let entries = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isDirectoryKey])
        else { return false }
        for case let url as URL in entries {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == false { return true }
        }
        return false
    }

    @MainActor
    static func confirm(_ plan: RemovalPlan) -> RemovalAnswer {
        let alert = NSAlert()
        let size = InstallSheetModel.size(plan.bytes)
        if plan.inPlace {
            alert.messageText = String(localized: "Remove \(plan.game.name) from the Library?")
            alert.informativeText = String(localized: "The game’s files stay where they are. Its Wine prefix and Cartouche’s record of it move to the Trash, freeing \(size).")
        } else {
            alert.messageText = String(localized: "Uninstall \(plan.game.name)?")
            alert.informativeText = String(localized: "The game and its Wine prefix move to the Trash, freeing \(size).")
        }
        let keep = NSButton(checkboxWithTitle: String(localized: "Keep save files"), target: nil, action: nil)
        keep.state = .on
        if plan.hasSaves { alert.accessoryView = keep }
        alert.addButton(withTitle: String(localized: "Move to Trash"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return .cancel }
        return .moveToTrash(keepSaves: keep.state == .on)
    }
}
