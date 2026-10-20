import Foundation

// Saves and save states in iCloud Drive: Cartouche's folders become links into the user's iCloud Drive folder
// — Cartouche has no iCloud container of its own — so RetroArch and every signed-in Mac share the files.
public struct CloudSaves: Sendable {

    public static var iCloudDrive: URL {
        URL.homeDirectory.appending(path: "Library/Mobile Documents/com~apple~CloudDocs", directoryHint: .isDirectory)
    }

    public let paths: RetroArchPaths
    public let cloud: URL

    public init(paths: RetroArchPaths, drive: URL = CloudSaves.iCloudDrive) {
        self.paths = paths
        cloud = drive.appending(path: "Cartouche", directoryHint: .isDirectory)
    }

    public var isAvailable: Bool {
        var folder: ObjCBool = false
        return FileManager.default.fileExists(atPath: cloud.deletingLastPathComponent().path(percentEncoded: false), isDirectory: &folder)
            && folder.boolValue
    }

    private var pairs: [(local: URL, cloud: URL)] {
        [(paths.saves, cloud.appending(path: "Saves", directoryHint: .isDirectory)),
         (paths.states, cloud.appending(path: "States", directoryHint: .isDirectory))]
    }

    static func path(_ url: URL) -> String { url.path(percentEncoded: false).trimmingSuffix("/") }

    static func link(at url: URL) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: path(url))
    }

    public var isOn: Bool {
        pairs.allSatisfy { Self.link(at: $0.local) == Self.path($0.cloud) }
    }

    // Moves what this Mac has into iCloud Drive, the newer copy winning, and links the folders there.
    public func turnOn() throws {
        let files = FileManager.default
        for (local, remote) in pairs {
            try files.createDirectory(at: remote, withIntermediateDirectories: true)
            if Self.link(at: local) == Self.path(remote) { continue }
            if files.fileExists(atPath: Self.path(local)) {
                try Self.merge(from: local, into: remote, move: true)
                try files.removeItem(at: local)
            }
            try files.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
            try files.createSymbolicLink(atPath: Self.path(local), withDestinationPath: Self.path(remote))
        }
    }

    // Folders of this Mac again, with a copy of what iCloud Drive holds. The copy is staged and swapped in, so a failed one leaves the link in place.
    public func turnOff() throws {
        let files = FileManager.default
        for (local, remote) in pairs where Self.link(at: local) != nil {
            let staging = local.deletingLastPathComponent()
                .appending(path: ".\(local.lastPathComponent).cartouche-staging", directoryHint: .isDirectory)
            try? files.removeItem(at: staging)
            try files.createDirectory(at: staging, withIntermediateDirectories: true)
            do {
                if files.fileExists(atPath: Self.path(remote)) { try Self.merge(from: remote, into: staging, move: false) }
            } catch {
                try? files.removeItem(at: staging)
                throw error
            }
            try files.removeItem(atPath: Self.path(local))
            try files.moveItem(at: staging, to: local)
        }
    }

    // Before a launch: iCloud Drive may have lost the folders, and RetroArch cannot write through a link to nothing
    public func ensure() throws {
        guard isOn else { return }
        for (_, remote) in pairs { try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true) }
    }

    static func merge(from source: URL, into target: URL, move: Bool) throws {
        let files = FileManager.default
        let base = link(at: source) ?? path(source)
        guard let walker = files.enumerator(atPath: base) else { return }
        while let relative = walker.nextObject() as? String {
            // iCloud Drive's dataless stubs, named .name.icloud, are not saves
            let name = (relative as NSString).lastPathComponent
            if name.hasPrefix("."), name.hasSuffix(".icloud") { continue }
            let file = URL(fileURLWithPath: base).appending(path: relative)
            let values = try file.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
            let destination = target.appending(path: relative)
            if values.isDirectory == true {
                try files.createDirectory(at: destination, withIntermediateDirectories: true)
                continue
            }
            if files.fileExists(atPath: path(destination)) {
                let theirs = (try? destination.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                guard (values.contentModificationDate ?? .distantPast) > theirs else { continue }
                try files.removeItem(at: destination)
            }
            if move { try files.moveItem(at: file, to: destination) } else { try files.copyItem(at: file, to: destination) }
        }
    }
}

private extension String {
    func trimmingSuffix(_ suffix: String) -> String {
        hasSuffix(suffix) && count > 1 ? String(dropLast(suffix.count)) : self
    }
}
