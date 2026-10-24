import Foundation

public enum CloudSavesError: Error, Equatable, LocalizedError {
    case notDownloaded

    public var errorDescription: String? {
        String(localized: "Some saves in iCloud Drive are not downloaded to this Mac yet. Try again when it is online.", bundle: .module)
    }
}

// Saves and save states in iCloud Drive: Cartouche's folders become links into the user's iCloud Drive folder
// — Cartouche has no iCloud container of its own — so RetroArch and every signed-in Mac share the files.
public struct CloudSaves: Sendable {

    public static var iCloudDrive: URL {
        URL.homeDirectory.appending(path: "Library/Mobile Documents/com~apple~CloudDocs", directoryHint: .isDirectory)
    }

    public let paths: RetroArchPaths
    public let cloud: URL
    // Asks iCloud Drive for an evicted file; the wait for it is bounded by `timeout`
    private let fetch: @Sendable (URL) throws -> Void
    private let timeout: Duration

    public init(paths: RetroArchPaths, drive: URL = CloudSaves.iCloudDrive, timeout: Duration = .seconds(120),
                fetch: @escaping @Sendable (URL) throws -> Void = {
                    try FileManager.default.startDownloadingUbiquitousItem(at: $0)
                }) {
        self.paths = paths
        cloud = drive.appending(path: "Cartouche", directoryHint: .isDirectory)
        self.fetch = fetch
        self.timeout = timeout
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
    // Evicted cloud files are downloaded first, so a local copy is never weighed against a missing one.
    public func turnOn() async throws {
        let files = FileManager.default
        for (local, remote) in pairs {
            try files.createDirectory(at: remote, withIntermediateDirectories: true)
            if Self.link(at: local) == Self.path(remote) { continue }
            try await download(remote)
            if files.fileExists(atPath: Self.path(local)) {
                try Self.merge(from: local, into: remote, move: true)
                try files.removeItem(at: local)
            }
            try files.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
            try files.createSymbolicLink(atPath: Self.path(local), withDestinationPath: Self.path(remote))
        }
    }

    // Folders of this Mac again, with a copy of what iCloud Drive holds. The copy is staged and swapped in, so a failed one leaves the link in place.
    // Evicted files are downloaded first; nothing is switched while one is still only a placeholder.
    public func turnOff() async throws {
        let files = FileManager.default
        for (local, remote) in pairs where Self.link(at: local) != nil {
            if files.fileExists(atPath: Self.path(remote)) { try await download(remote) }
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

    func download(_ folder: URL) async throws {
        var waiting = Self.evicted(in: folder)
        guard !waiting.isEmpty else { return }
        for file in waiting { try? fetch(file) }
        let deadline = ContinuousClock.now + timeout
        while true {
            waiting = waiting.filter { !FileManager.default.fileExists(atPath: Self.path($0)) }
            if waiting.isEmpty { return }
            guard ContinuousClock.now < deadline else { throw CloudSavesError.notDownloaded }
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    // iCloud Drive's placeholders (.name.icloud) under a folder whose file is not here, by the name they download to
    static func evicted(in folder: URL) -> [URL] {
        let base = link(at: folder) ?? path(folder)
        guard let walker = FileManager.default.enumerator(atPath: base) else { return [] }
        var found: [URL] = []
        while let relative = walker.nextObject() as? String {
            if let real = realFile(of: URL(fileURLWithPath: base).appending(path: relative)),
               !FileManager.default.fileExists(atPath: path(real)) {
                found.append(real)
            }
        }
        return found
    }

    static func realFile(of stub: URL) -> URL? {
        let name = stub.lastPathComponent
        guard name.hasPrefix("."), name.hasSuffix(".icloud"), name.count > ".icloud".count + 1 else { return nil }
        return stub.deletingLastPathComponent().appending(path: String(name.dropFirst().dropLast(".icloud".count)))
    }

    static func stub(of file: URL) -> URL {
        file.deletingLastPathComponent().appending(path: ".\(file.lastPathComponent).icloud")
    }

    static func merge(from source: URL, into target: URL, move: Bool) throws {
        let files = FileManager.default
        let base = link(at: source) ?? path(source)
        guard let walker = files.enumerator(atPath: base) else { return }
        while let relative = walker.nextObject() as? String {
            let file = URL(fileURLWithPath: base).appending(path: relative)
            // A placeholder is not a save; one whose file is still missing is a save that cannot be copied yet
            if let real = realFile(of: file) {
                guard files.fileExists(atPath: path(real)) else { throw CloudSavesError.notDownloaded }
                continue
            }
            let values = try file.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
            let destination = target.appending(path: relative)
            if values.isDirectory == true {
                try files.createDirectory(at: destination, withIntermediateDirectories: true)
                continue
            }
            // A placeholder there is the cloud's copy, not downloaded: it exists, and is never overwritten unseen
            if !files.fileExists(atPath: path(destination)), files.fileExists(atPath: path(stub(of: destination))) {
                throw CloudSavesError.notDownloaded
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
