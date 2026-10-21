import Foundation

/// Where a folder walk must never look: developer working copies and the
/// system's or the app's own support data. Explicitly dropped files still
/// identify; these fences only bound a walk.
public enum ScanFence {

    /// A folder the walk must not descend into: a git working copy (its `.git`
    /// entry is a folder in a clone, a file in a linked worktree) or a Library.
    public static func blocks(_ directory: URL) -> Bool {
        directory.lastPathComponent == "Library"
            || FileManager.default.fileExists(
                atPath: directory.appending(path: ".git").path(percentEncoded: false))
    }

    /// A scan root refused outright: a working copy itself, anywhere inside a
    /// Library (macOS's or Cartouche's own data lives there), or a bundle.
    public static func blocks(root url: URL) -> Bool {
        blocks(url)
            || url.resolvingSymlinksInPath().pathComponents.contains("Library")
            || (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) == true
    }
}
