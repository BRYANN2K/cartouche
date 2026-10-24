//// Removing a console game or a whole console: only files inside Cartouche's own folders ever move, and only to the Trash.
//// A ROM in the user's own folders stays where it is; a save folder linked into iCloud Drive is the user's too.

import AppKit
import Foundation
import RetroArchKit

// What removing a console game takes out: only the files Cartouche owns — a ROM it copied into its
// own folder — plus the game's save data inside Cartouche's folders. The user's files are never listed.
struct ConsoleGameRemoval: Sendable, Equatable {
    let game: ConsoleGame
    // The Cartouche folder the listed files live in; kept copies keep their layout under it
    let root: URL
    // Game files inside Cartouche's folder: a copied ROM, its discs and .cue track files
    let roms: [URL]
    // Its save files and save states inside Cartouche's folders
    let saves: [URL]
    let bytes: Int64

    var ownsROM: Bool { !roms.isEmpty }
    var hasSaves: Bool { !saves.isEmpty }
    var title: String { ConsoleUninstall.itemTitle(ownsROM: ownsROM) }
}

// What removing a whole console takes out: its core files. The games' files are never part of it.
struct ConsoleRemoval: Sendable, Equatable {
    let console: Console
    let games: Int
    let files: [URL]
}

struct ConsoleUninstall: Sendable {

    var trash: @Sendable (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    var saves: URL = SupportPaths.saves
    var measure: @Sendable (URL) -> Int64 = { PrefixStore.directoryBytes($0) }

    // "Move ROM to Trash…" only for a ROM Cartouche copied into its own folder; a file in a watched
    // or user folder is the user's and only ever leaves the library.
    static func itemTitle(ownsROM: Bool) -> String {
        ownsROM ? String(localized: "Move ROM to Trash…") : String(localized: "Remove from Library…")
    }

    // Inside Cartouche's own folder, links resolved — a saves folder linked into iCloud Drive is not Cartouche's.
    static func owns(_ file: URL, in root: URL) -> Bool {
        let path = file.resolvingSymlinksInPath().path(percentEncoded: false)
        return path.hasPrefix(basePath(root) + "/")
    }

    // The root's resolved path without its directory-hint slash, so base + "/" is a real prefix
    private static func basePath(_ root: URL) -> String {
        var base = root.resolvingSymlinksInPath().path(percentEncoded: false)
        while base.hasSuffix("/") { base.removeLast() }
        return base
    }

    // A real file inside Cartouche's folder — the "Move ROM to Trash…" case the menu title and the plan share.
    static func ownsROM(_ file: URL, in root: URL) -> Bool {
        owns(file, in: root) && FileManager.default.fileExists(atPath: file.path(percentEncoded: false))
    }

    func plan(for game: ConsoleGame, in paths: RetroArchPaths) -> ConsoleGameRemoval {
        let fm = FileManager.default
        var roms: [URL] = []
        for file in [game.fileURL] + game.discURLs where Self.ownsROM(file, in: paths.root) {
            roms.append(file)
            // A .cue carries its track files: same name, another extension, same folder
            guard file.pathExtension.lowercased() == "cue" else { continue }
            for ext in ["bin", "img", "iso"] {
                let track = file.deletingPathExtension().appendingPathExtension(ext)
                if Self.owns(track, in: paths.root), fm.fileExists(atPath: track.path(percentEncoded: false)) {
                    roms.append(track)
                }
            }
        }
        let saves = Self.saveFiles(for: game, in: paths)
        let bytes = (roms + saves).reduce(0) { $0 + measure($1) }
        return ConsoleGameRemoval(game: game, root: paths.root, roms: roms, saves: saves, bytes: bytes)
    }

    // The game's .srm-style files under saves/, its .state* files and thumbnails under states/ —
    // only what sits inside Cartouche's folder, so linked-out iCloud saves stay untouched.
    static func saveFiles(for game: ConsoleGame, in paths: RetroArchPaths) -> [URL] {
        let fm = FileManager.default
        var found: [URL] = []
        for (folder, prefix) in [(paths.saves, game.contentName + "."), (paths.states, game.contentName + ".state")] {
            guard let walker = fm.enumerator(at: folder.resolvingSymlinksInPath(),
                                             includingPropertiesForKeys: [.isDirectoryKey]) else { continue }
            for case let file as URL in walker where file.lastPathComponent.hasPrefix(prefix) {
                if (try? file.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    walker.skipDescendants()
                }
                if owns(file, in: paths.root) { found.append(file) }
            }
        }
        return found.sorted { $0.path(percentEncoded: false) < $1.path(percentEncoded: false) }
    }

    // The saves are copied out first, so a failed copy leaves every file where it was.
    func remove(_ plan: ConsoleGameRemoval, keepSaves: Bool) throws {
        if keepSaves { try copySaves(plan) }
        let fm = FileManager.default
        for file in plan.saves + plan.roms where fm.fileExists(atPath: file.path(percentEncoded: false)) {
            try trash(file)
        }
    }

    private func copySaves(_ plan: ConsoleGameRemoval) throws {
        let fm = FileManager.default
        let base = Self.basePath(plan.root) + "/"
        let target = GameUninstall.unusedFolder(
            saves.appending(path: "\(plan.game.console)-\(plan.game.contentName)", directoryHint: .isDirectory))
        for file in plan.saves {
            let relative = String(file.resolvingSymlinksInPath().path(percentEncoded: false).dropFirst(base.count))
            let destination = target.appending(path: relative)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: file, to: destination)
        }
    }

    @MainActor
    static func confirm(_ plan: ConsoleGameRemoval) -> RemovalAnswer {
        let alert = NSAlert()
        let game = plan.game
        let size = InstallSheetModel.size(plan.bytes)
        if plan.ownsROM {
            alert.messageText = String(localized: "Move \(game.name)’s game file to the Trash?")
            alert.informativeText = gameInfo(plan, size: size)
        } else {
            alert.messageText = String(localized: "Remove \(game.name) from the Library?")
            alert.informativeText = userInfo(plan)
        }
        let keep = NSButton(checkboxWithTitle: String(localized: "Keep save files"), target: nil, action: nil)
        keep.state = .on
        if plan.hasSaves { alert.accessoryView = keep }
        alert.addButton(withTitle: plan.ownsROM ? String(localized: "Move to Trash") : String(localized: "Remove"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return .cancel }
        return .moveToTrash(keepSaves: keep.state == .on)
    }

    // Where the moving files live: the file's own path for one, the folders they share for many.
    private static func gameInfo(_ plan: ConsoleGameRemoval, size: String) -> String {
        let at = plan.roms.count == 1
            ? plan.roms[0].path(percentEncoded: false)
            : Set(plan.roms.map { $0.deletingLastPathComponent().path(percentEncoded: false) }).sorted().joined(separator: ", ")
        switch (plan.roms.count, plan.hasSaves) {
        case (1, true):
            return String(localized: "The file at \(at) moves to the Trash, freeing \(size). Its record, save files and save states are removed.")
        case (1, false):
            return String(localized: "The file at \(at) moves to the Trash, freeing \(size). Its record is removed.")
        case (_, true):
            return String(localized: "The files in \(at) move to the Trash, freeing \(size). Its record, save files and save states are removed.")
        default:
            return String(localized: "The files in \(at) move to the Trash, freeing \(size). Its record is removed.")
        }
    }

    private static func userInfo(_ plan: ConsoleGameRemoval) -> String {
        let files = [plan.game.fileURL] + plan.game.discURLs
        let at = files.count == 1
            ? files[0].path(percentEncoded: false)
            : Set(files.map { $0.deletingLastPathComponent().path(percentEncoded: false) }).sorted().joined(separator: ", ")
        switch (files.count, plan.hasSaves) {
        case (1, true):
            return String(localized: "The game file stays at \(at). Its record is removed, and its save files and save states move to the Trash.")
        case (1, false):
            return String(localized: "The game file stays at \(at). Its record is removed.")
        case (_, true):
            return String(localized: "The game files stay in \(at). Its record is removed, and its save files and save states move to the Trash.")
        default:
            return String(localized: "The game files stay in \(at). Its record is removed.")
        }
    }

    @MainActor
    static func confirm(_ plan: ConsoleRemoval) -> Bool {
        let alert = NSAlert()
        alert.messageText = String(localized: "Remove \(plan.console.name)?")
        let names = plan.files.map(\.lastPathComponent).joined(separator: ", ")
        switch (plan.files.isEmpty, plan.games) {
        case (true, 0):
            alert.informativeText = String(localized: "The console leaves your library; nothing moves to the Trash.")
        case (true, 1):
            alert.informativeText = String(localized: "Its game is hidden and its file stays on disk.")
        case (true, _):
            alert.informativeText = String(localized: "Its \(plan.games) games are hidden and their files stay on disk.")
        case (false, 0):
            alert.informativeText = String(localized: "Its emulator files move to the Trash: \(names).")
        case (false, 1):
            alert.informativeText = String(localized: "Its emulator files move to the Trash: \(names). Its game is hidden and its file stays on disk.")
        default:
            alert.informativeText = String(localized: "Its emulator files move to the Trash: \(names). Its \(plan.games) games are hidden and their files stay on disk.")
        }
        alert.addButton(withTitle: plan.files.isEmpty ? String(localized: "Remove") : String(localized: "Move to Trash"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.buttons.first?.hasDestructiveAction = true
        return alert.runModal() == .alertFirstButtonReturn
    }
}

extension ConsoleCenter {

    // "Remove from Library…" / "Move ROM to Trash…": the record always goes; a ROM inside
    // Cartouche's own folder goes with it, the user's file never does.
    func removeGame(_ id: String) async {
        problem = nil
        guard let game = game(id) else { return }
        if isPlaying(id) {
            problem = String(localized: "\(game.name) is playing. Quit the game first.")
            return
        }
        let uninstall = uninstall, paths = paths
        let plan = await Task.detached { uninstall.plan(for: game, in: paths) }.value
        guard case .moveToTrash(let keepSaves) = confirmGameRemoval(plan) else { return }
        do {
            try uninstall.remove(plan, keepSaves: keepSaves)
            try await store.remove(id)
            statesCache[id] = nil
            biosCache[id] = nil
            library?.clearCover(for: id)
            await reload()
        } catch {
            problem = String(localized: "Cartouche couldn’t remove \(game.name): \(error.localizedDescription)")
        }
    }
}
