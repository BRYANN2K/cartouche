// Delete the installer files: only when the user asks and confirms, and only
// to the Trash. The files are trashed one by one, so an installer dropped
// straight into Downloads never takes the rest of Downloads with it.

import Foundation

struct InstallerCleanup: Sendable {

    var trash: @Sendable (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    var home: URL = SupportPaths.home

    // setup.exe, its parts and the checksum manifest. The folder goes too when
    // nothing else is left in it and it is not one of the user's own folders.
    func run(files: [URL], folder: URL) throws {
        let fm = FileManager.default
        for file in files where fm.fileExists(atPath: file.path(percentEncoded: false)) {
            try trash(file)
        }
        // A subfolder that held only installer files, like MD5/.
        let path = { (url: URL) in url.standardizedFileURL.path(percentEncoded: false).trimmingCharacters(in: .init(charactersIn: "/")) }
        let base = path(folder)
        let parents = Set(files.map { path($0.deletingLastPathComponent()) }).filter { $0.hasPrefix(base + "/") }
        for sub in parents.sorted() where isEmpty(URL(filePath: "/" + sub)) {
            try trash(URL(filePath: "/" + sub))
        }
        if isEmpty(folder), !isProtected(folder) { try trash(folder) }
    }

    private func isEmpty(_ folder: URL) -> Bool {
        let left = (try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? ["?"]
        return left.allSatisfy { $0 == ".DS_Store" }
    }

    func isProtected(_ folder: URL) -> Bool {
        let path = folder.standardizedFileURL.path(percentEncoded: false).trimmingCharacters(in: .init(charactersIn: "/"))
        let homePath = home.standardizedFileURL.path(percentEncoded: false).trimmingCharacters(in: .init(charactersIn: "/"))
        let own = ["", "Downloads", "Desktop", "Documents", "Library", "Movies", "Music", "Pictures", "Public", "Applications"]
            .map { ($0.isEmpty ? homePath : homePath + "/" + $0) }
        let volumeRoot = path.split(separator: "/").count <= 2 && path.hasPrefix("Volumes")
        return own.contains(path) || volumeRoot || path.split(separator: "/").count <= 1
    }
}
