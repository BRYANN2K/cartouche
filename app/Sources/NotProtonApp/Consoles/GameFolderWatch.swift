// Game folders: watched with FSEvents, scanned when they change. Games of added
// consoles that the database knows join the library on their own; games of the
// other consoles are counted, for the Add Consoles sheet.

import Foundation
import RetroArchKit

extension ConsoleCenter {

    var folderPaths: [String] { folderList?.paths ?? [] }

    // Reads the choices, watches the folders, and follows the list as it changes
    func startWatching() async {
        folderChoices = WatchedFolders.load(paths)
        watch()
        followList()
        await scanFolders()
    }

    func stopWatching() {
        watcher?.stop()
        watcher = nil
    }

    func addFolder(_ url: URL) async {
        folderList?.add(url)
        watch()
        await scanFolders()
    }

    func removeFolder(_ path: String) async {
        folderList?.remove(URL(filePath: path, directoryHint: .isDirectory))
        folderCounts[path] = nil
        watch()
        await scanFolders()
    }

    func setAddAutomatically(_ on: Bool) async {
        folderChoices.addAutomatically = on
        do {
            try folderChoices.save(paths)
        } catch {
            problem = error.localizedDescription
        }
        if on { await scanFolders() }
    }

    // Onboarding and Settings > Library change the list; the watch follows
    private func followList() {
        guard let list = folderList else { return }
        withObservationTracking {
            _ = list.paths
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.watch()
                self.followList()
                await self.scanFolders()
            }
        }
    }

    private func watch() {
        if watcher == nil {
            watcher = FolderWatcher { [weak self] in
                Task { @MainActor in self?.folderChanged() }
            }
        }
        watcher?.watch(folderPaths.map { URL(filePath: $0, directoryHint: .isDirectory) })
    }

    private func folderChanged() {
        if scan != nil {
            scanAgain = true
            return
        }
        scan = Task { [weak self] in
            await self?.scanFolders()
            self?.scan = nil
        }
    }

    // One pass over every folder. A file still being copied is left for the
    // next pass, a second later.
    func scanFolders() async {
        let roots = folderPaths.map { URL(filePath: $0, directoryHint: .isDirectory) }
        let files = Identifier.files(in: roots)
        let known = await store.knownFiles()
        let identifier = identifier
        var counts: [String: Int] = [:]
        var perFolder: [String: Int] = [:]
        var new: [ConsoleGame] = []
        var busy = false
        for file in files {
            let path = file.path(percentEncoded: false)
            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let modified = values?.contentModificationDate ?? .distantPast
            if Date().timeIntervalSince(modified) < 1 {
                busy = true
                continue
            }
            let stamp = "\(values?.fileSize ?? 0)|\(modified.timeIntervalSince1970)"
            let found: Identification
            if let cached = seen[path], cached.stamp == stamp {
                found = cached.found
            } else {
                found = await identifier.identify(file)
                seen[path] = (stamp, found)
            }
            // Recognized, or a file type only one console plays
            guard let console = found.isRecognized ? found.console
                    : (found.candidates.count == 1 ? found.candidates.first : nil) else { continue }
            if let root = roots.first(where: { path.hasPrefix($0.path(percentEncoded: false)) }) {
                perFolder[root.plainPath, default: 0] += 1
            }
            if !isAdded(console) {
                counts[console, default: 0] += 1
            } else if found.isRecognized, folderChoices.addAutomatically, !known.contains(path), let game = found.game() {
                new.append(game)
            }
        }
        self.found = counts
        folderCounts = perFolder
        if !new.isEmpty {
            do {
                try await store.add(new)
            } catch {
                problem = error.localizedDescription
            }
            await reload()
        }
        if busy || scanAgain {
            scanAgain = false
            try? await Task.sleep(for: .seconds(1))
            await scanFolders()
        }
    }
}

// How Settings > Library describes a watched folder
enum WatchedFolderState {
    static func text(_ path: String, count: Int) -> String {
        guard FileManager.default.fileExists(atPath: path) else {
            return String(localized: "Watched when the disk is connected")
        }
        switch count {
        case 0: return String(localized: "Watched. No games found yet")
        case 1: return String(localized: "Watched. 1 game found")
        default: return String(localized: "Watched. \(count) games found")
        }
    }
}
