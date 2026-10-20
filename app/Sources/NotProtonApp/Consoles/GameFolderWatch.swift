import Foundation
import RetroArchKit

extension ConsoleCenter {

    var folderPaths: [String] { folderList?.paths ?? [] }

    func startWatching() async {
        folderChoices = WatchedFolders.load(paths)
        watch()
        followList()
        folderChanged()
        await scan?.value
    }

    func stopWatching() {
        watcher?.stop()
        watcher = nil
    }

    func addFolder(_ url: URL) async {
        folderList?.add(url)
        watch()
        folderChanged()
        await scan?.value
    }

    func removeFolder(_ path: String) async {
        folderList?.remove(URL(filePath: path, directoryHint: .isDirectory))
        folderCounts[path] = nil
        watch()
        folderChanged()
        await scan?.value
    }

    func setAddAutomatically(_ on: Bool) async {
        folderChoices.addAutomatically = on
        do {
            try folderChoices.save(paths)
        } catch {
            problem = error.localizedDescription
        }
        if on {
            folderChanged()
            await scan?.value
        }
    }

    private func followList() {
        guard let list = folderList else { return }
        withObservationTracking {
            _ = list.paths
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.watch()
                self.followList()
                self.folderChanged()
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

    func rescanFolders() async {
        folderChanged()
        await scan?.value
    }

    func folderChanged() {
        if scan != nil {
            scanAgain = true
            return
        }
        scan = Task { [weak self] in
            await self?.scanLoop()
            self?.scan = nil
        }
    }

    private struct FoundFile: Sendable {
        var url: URL
        var stamp: String
        var busy: Bool
    }

    private nonisolated static func listFiles(in roots: [URL]) -> [FoundFile] {
        Identifier.files(in: roots).map { file in
            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let modified = values?.contentModificationDate ?? .distantPast
            let busy = abs(Date().timeIntervalSince(modified)) < 1
            return FoundFile(url: file, stamp: "\(values?.fileSize ?? 0)|\(modified.timeIntervalSince1970)", busy: busy)
        }
    }

    private func scanLoop() async {
        var attempts = 0
        while !Task.isCancelled {
            let busy = await scanPass()
            attempts = busy ? attempts + 1 : 0
            let again = scanAgain
            scanAgain = false
            guard again || (busy && attempts < 60) else { return }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    // One pass over every folder. A file still being copied is left for the next pass, a second later — 60 passes at most, the events keep coming.
    @discardableResult
    private func scanPass() async -> Bool {
        let roots = folderPaths.map { URL(filePath: $0, directoryHint: .isDirectory) }
        let files = await Task.detached { Self.listFiles(in: roots) }.value
        let known = await store.knownFiles()
        let identifier = identifier
        var counts: [String: Int] = [:]
        var perFolder: [String: Int] = [:]
        var new: [ConsoleGame] = []
        var busy = false
        for file in files {
            if file.busy { busy = true; continue }
            let path = file.url.path(percentEncoded: false)
            let found: Identification
            if let cached = seen[path], cached.stamp == file.stamp {
                found = cached.found
            } else {
                found = await identifier.identify(file.url)
                seen[path] = (file.stamp, found)
            }
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
        return busy
    }
}

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
