import Foundation

public struct InstalledEmulator: Sendable, Equatable, Identifiable {
    public var emulator: StandaloneEmulator
    public var app: URL
    public var executable: URL
    // CFBundleShortVersionString, or CFBundleVersion when the app has no other
    public var version: String?

    public var id: String { emulator.id }

    public var title: String { version.map { "\(emulator.name) \($0)" } ?? emulator.name }

    public init(emulator: StandaloneEmulator, app: URL, executable: URL, version: String?) {
        self.emulator = emulator
        self.app = app
        self.executable = executable
        self.version = version
    }
}

// Finds the standalone emulators the user installed in /Applications or ~/Applications, one folder deep. It reads Info.plist files and nothing else.
public struct EmulatorDetector: Sendable {

    public var folders: [URL]

    public init(folders: [URL] = EmulatorDetector.applicationFolders) {
        self.folders = folders
    }

    public static var applicationFolders: [URL] {
        [URL(fileURLWithPath: "/Applications", isDirectory: true),
         URL.homeDirectory.appending(path: "Applications", directoryHint: .isDirectory)]
    }

    // One app per emulator, in catalog order; the first folder wins
    public func installed() -> [InstalledEmulator] {
        var found: [String: InstalledEmulator] = [:]
        for app in apps() {
            guard let info = Self.read(app), found[info.emulator.id] == nil else { continue }
            found[info.emulator.id] = info
        }
        return EmulatorCatalog.all.compactMap { found[$0.id] }
    }

    func apps() -> [URL] {
        let manager = FileManager.default
        var apps: [URL] = []
        for folder in folders {
            let items = (try? manager.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
            let sorted = items.sorted { $0.lastPathComponent < $1.lastPathComponent }
            apps += sorted.filter { $0.pathExtension == "app" }
            for sub in sorted where sub.pathExtension.isEmpty && Self.isFolder(sub) {
                let inner = (try? manager.contentsOfDirectory(at: sub, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
                apps += inner.filter { $0.pathExtension == "app" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            }
        }
        return apps
    }

    public static func read(_ app: URL) -> InstalledEmulator? {
        let plist = app.appending(path: "Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
        else { return nil }
        let identifier = info["CFBundleIdentifier"] as? String
        let name = app.deletingPathExtension().lastPathComponent
        guard let emulator = EmulatorCatalog.all.first(where: { emulator in
            identifier.map { emulator.bundleIDs.contains($0) } ?? false
        }) ?? EmulatorCatalog.all.first(where: { $0.appNames.contains(name) })
        else { return nil }
        let executableName = (info["CFBundleExecutable"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? emulator.executableName
        let executable = app.appending(path: "Contents/MacOS/\(executableName)")
        guard FileManager.default.isExecutableFile(atPath: executable.path(percentEncoded: false)) else { return nil }
        let version = (info["CFBundleShortVersionString"] as? String ?? info["CFBundleVersion"] as? String)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
        return InstalledEmulator(emulator: emulator, app: app, executable: executable, version: version)
    }

    private static func isFolder(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
}
