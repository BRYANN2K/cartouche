import Foundation

// A store game's folder may sit in a folder the user picked: only what Cartouche put there goes, to the Trash
enum StoreUninstall {
    static let owned = ["game", "pfx"]

    static func clear(_ folder: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                      trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) {
        let fm = FileManager.default
        guard !isProtected(folder, home: home) else { return }
        let items = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for item in items where owned.contains(item.lastPathComponent) || item.pathExtension == "log" {
            try? trash(item)
        }
        if (try? fm.contentsOfDirectory(atPath: folder.path(percentEncoded: false)))?.isEmpty == true {
            try? fm.removeItem(at: folder)
        }
    }

    // The home folder, its standard folders and a volume root are never a game's own folder
    static func isProtected(_ folder: URL, home: URL) -> Bool {
        let path = folder.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false).trimmingSlash
        let home = home.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false).trimmingSlash
        let standard = ["Applications", "Desktop", "Documents", "Downloads", "Library", "Movies", "Music", "Pictures", "Public", "Games"]
        if path.isEmpty || path == home || standard.contains(where: { path == "\(home)/\($0)" }) { return true }
        if path == "/Volumes" || (path.hasPrefix("/Volumes/") && path.dropFirst("/Volumes/".count).split(separator: "/").count == 1) { return true }
        return path.split(separator: "/").count <= 1
    }

    // A folder picked in the install sheet holds the game in its own subfolder, never loose
    static func folder(in picked: URL, title: String, id: String) -> URL {
        picked.appending(path: "\(GameFolder.slug(title))-\(StoreFolders.safe(id))", directoryHint: .isDirectory)
    }
}

private extension String {
    var trimmingSlash: String { hasSuffix("/") && count > 1 ? String(dropLast()) : self }
}
