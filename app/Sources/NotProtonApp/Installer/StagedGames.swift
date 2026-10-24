//// A dropped archive unpacks in Caches, which macOS may purge. A game imported from there never stays:
//// its folder moves into the game's own prefix, the way a copy lands. Records written before that still
//// point into Caches; they are moved once at startup, the source deleted only after the record is rewritten.

import Foundation
import InstallerKit

enum GameMove {

    struct Tally: Equatable, Sendable {
        var files = 0
        var bytes: Int64 = 0
    }

    static func tally(_ root: URL) -> Tally {
        var tally = Tally()
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return tally }
        for case let url as URL in walk {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isDirectory == true, values.isSymbolicLink != true { continue }
            tally.files += 1
            tally.bytes += Int64(values.fileSize ?? 0)
        }
        return tally
    }

    // Puts source's files at target, which must not exist. On one volume it is a rename and source is gone;
    // across volumes the files are copied to a hidden sibling, checked, then renamed into place, and source
    // stays for the caller to delete once nothing points at it. A failure leaves source as it was.
    @discardableResult
    static func place(
        _ source: URL, at target: URL, allowRename: Bool = true,
        freeSpace: (URL) -> Int64? = { Disk.freeBytes(at: $0) },
        stop: StopFlag = StopFlag(), progress: (Int64) -> Void = { _ in }
    ) throws -> Int64 {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path(percentEncoded: false)) else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: source.path(percentEncoded: false)])
        }
        let parent = target.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        if allowRename, rename(source.path(percentEncoded: false), target.path(percentEncoded: false)) == 0 {
            return tally(target).bytes
        }
        let expected = tally(source)
        if let free = freeSpace(parent), free < expected.bytes {
            throw CocoaError(.fileWriteOutOfSpace, userInfo: [NSFilePathErrorKey: target.path(percentEncoded: false)])
        }
        let temp = parent.appending(path: ".\(target.lastPathComponent).moving")
        try? fm.removeItem(at: temp)
        do {
            let copied = try GameCopy.copyFiles(source, to: temp, stop: stop, progress: progress)
            guard tally(temp) == expected else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: target.path(percentEncoded: false)])
            }
            try fm.moveItem(at: temp, to: target)
            return copied
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
    }

    static func relocate(
        _ source: URL, to target: URL, freeSpace: @escaping @Sendable (URL) -> Int64?,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws -> Int64 {
        let stop = StopFlag()
        return try await withTaskCancellationHandler {
            try await Task.detached { try place(source, at: target, freeSpace: freeSpace, stop: stop, progress: progress) }.value
        } onCancel: {
            stop.set()
        }
    }
}

enum StagedGames {

    static func isStaged(_ url: URL, staging: URL = SupportPaths.dropStaging) -> Bool {
        inside(staging, url)
    }

    // Where an extracted game lives for good: drive_c/Games/<Name> in its own prefix, as a copied import.
    static func home(for name: String, prefix: URL) -> URL {
        WinePath.unix(InstallInputs(runnerID: "", gameName: name).installDir, prefix: prefix)
            ?? prefix.appending(path: "drive_c/Games/Game")
    }

    // Removes source once its files live elsewhere, then the empty folders it leaves in staging.
    static func discard(_ source: URL, staging: URL = SupportPaths.dropStaging) {
        let fm = FileManager.default
        guard isStaged(source, staging: staging) else { return }
        try? fm.removeItem(at: source)
        var dir = source.deletingLastPathComponent()
        while isStaged(dir, staging: staging),
              (try? fm.contentsOfDirectory(atPath: dir.path(percentEncoded: false)))?.isEmpty == true {
            try? fm.removeItem(at: dir)
            dir = dir.deletingLastPathComponent()
        }
    }

    // MARK: Records from before

    // Every record still pointing into staging is moved; a busy game waits for the next start. Returns the slugs moved.
    @discardableResult
    static func migrate(
        installs: URL = GameFolder.installs, staging: URL = SupportPaths.dropStaging,
        allowRename: Bool = true, freeSpace: (URL) -> Int64? = { Disk.freeBytes(at: $0) },
        inUse: (GameFolder) -> Bool = { PrefixStore.isInUse(root: $0.root, pfx: $0.prefix) }
    ) -> [String] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: installs, includingPropertiesForKeys: nil)) ?? []
        var moved: [String] = []
        for root in folders {
            let folder = GameFolder(root: root)
            guard let record = InstalledGames.record(in: folder), isStaged(record.exeURL, staging: staging) else { continue }
            guard !inUse(folder) else { continue }
            do {
                if try migrate(record, in: folder, staging: staging, allowRename: allowRename, freeSpace: freeSpace) {
                    moved.append(record.id)
                }
            } catch {
                AppLog.note("drop staging: \(record.id) stays where it is for now: \(error.localizedDescription)")
            }
        }
        return moved
    }

    // Files first, then the launcher, then the record, and only then the source goes: an interruption at any
    // step leaves either the old paths with their files, or files at the target that the next run adopts.
    static func migrate(
        _ record: InstalledGame, in folder: GameFolder, staging: URL = SupportPaths.dropStaging,
        allowRename: Bool = true, freeSpace: (URL) -> Int64? = { Disk.freeBytes(at: $0) }
    ) throws -> Bool {
        let fm = FileManager.default
        let source = URL(filePath: record.gameFolder ?? record.inferredGameFolder
                         ?? record.exeURL.deletingLastPathComponent().path(percentEncoded: false))
        guard isStaged(source, staging: staging) else { return false }
        let dest = home(for: record.name, prefix: URL(filePath: record.prefix))
        let exists = { (url: URL) in fm.fileExists(atPath: url.path(percentEncoded: false)) }

        var target = dest
        if exists(source) {
            // A complete copy left by an interrupted run is adopted; anything else at the target is kept aside.
            var n = 2
            while exists(target), GameMove.tally(target) != GameMove.tally(source) {
                target = dest.deletingLastPathComponent().appending(path: "\(dest.lastPathComponent) \(n)")
                n += 1
            }
            if !exists(target) {
                try GameMove.place(source, at: target, allowRename: allowRename, freeSpace: freeSpace)
            }
        } else {
            // Renamed by an earlier run that stopped before the record: the files are already home.
            guard exists(GameCopy.rebase(record.exeURL, from: source, to: dest)) else {
                AppLog.note("drop staging: \(record.id)'s files are gone from \(source.path(percentEncoded: false))")
                return false
            }
        }

        let exe = GameCopy.rebase(record.exeURL, from: source, to: target)
        guard !isStaged(exe, staging: staging) else { return false }
        try rebaseLauncher(folder.launcher, from: [source.path(percentEncoded: false)] + (record.gameFolder.map { [$0] } ?? []),
                           to: target.path(percentEncoded: false))
        var updated = record
        updated.exe = exe.path(percentEncoded: false)
        updated.gameFolder = nil
        if let dir = updated.verification?.gameDir, isStaged(URL(filePath: dir), staging: staging) {
            updated.verification?.gameDir = GameCopy.rebase(URL(filePath: dir), from: source, to: target).path(percentEncoded: false)
        }
        try InstalledGames.save(updated, in: folder)
        discard(source, staging: staging)
        return true
    }

    // The launch script names the game's folder in its cd and exec lines; only those paths change.
    static func rebaseLauncher(_ launcher: URL, from old: [String], to new: String) throws {
        guard var text = try? String(contentsOf: launcher, encoding: .utf8) else { return }
        let escape = { (path: String) in trimmed(path).replacingOccurrences(of: "'", with: "'\\''") }
        let replacement = escape(new)
        for path in Set(old.map(escape)) {
            text = text.replacingOccurrences(of: path + "/", with: replacement + "/")
                .replacingOccurrences(of: path + "'", with: replacement + "'")
        }
        try atomicReplace(launcher, with: Data(text.utf8), step: String(localized: "Write the game's launcher"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path(percentEncoded: false))
    }

    private static func trimmed(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    // Compared as written and resolved, with /private dropped: a purged child no longer resolves like its parent.
    private static func inside(_ parent: URL, _ child: URL) -> Bool {
        let bases = forms(parent).map { $0 + "/" }
        return forms(child).contains { path in bases.contains { path.hasPrefix($0) } }
    }

    private static func forms(_ url: URL) -> Set<String> {
        let standard = url.standardizedFileURL
        let paths = [standard, standard.resolvingSymlinksInPath()].map { trimmed($0.path(percentEncoded: false)) }
        return Set(paths.flatMap { [$0, $0.hasPrefix("/private/") ? String($0.dropFirst("/private".count)) : $0] })
    }
}
