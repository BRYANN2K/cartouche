import Darwin
import Foundation

enum SteamGameRemoval {
    struct Plan: Sendable {
        let appID: Int
        let libraries: [URL]
        let prefixes: [WinePrefix]
    }

    static func plan(appID: Int, files: SteamLocalFiles) -> Plan? {
        guard appID > 0 else { return nil }
        let libraries = files.libraries().filter {
            FileManager.default.fileExists(atPath: $0.appending(path: "steamapps").path)
        }
        guard libraries.contains(where: { FileManager.default.fileExists(atPath: manifest(appID, in: $0).path) }) else { return nil }
        let prefixes = libraries.compactMap { root -> WinePrefix? in
            let prefix = WinePrefix(appID: String(appID), name: nil, library: SteamLibrary(root: root), lastUsed: nil)
            return FileManager.default.fileExists(atPath: prefix.pfx.path) ? prefix : nil
        }
        return Plan(appID: appID, libraries: libraries, prefixes: prefixes)
    }

    static func finish(_ plan: Plan, polls: Int = 120, interval: Duration = .seconds(1)) async throws -> Bool {
        var absent = false
        for _ in 0..<polls {
            try Task.checkCancellation()
            let missing = await Task.detached { isUninstalled(plan) }.value
            if missing && absent {
                return try await Task.detached { try removePrefixes(plan) }.value
            }
            absent = missing
            try await Task.sleep(for: interval)
        }
        return false
    }

    static func isUninstalled(_ plan: Plan) -> Bool {
        !plan.libraries.isEmpty && plan.libraries.allSatisfy {
            FileManager.default.fileExists(atPath: $0.appending(path: "steamapps").path)
                && !FileManager.default.fileExists(atPath: manifest(plan.appID, in: $0).path)
        }
    }

    static func removePrefixes(_ plan: Plan) throws -> Bool {
        guard isUninstalled(plan) else { return false }
        for prefix in plan.prefixes {
            guard FileManager.default.fileExists(atPath: prefix.root.path) else { continue }
            let parent = prefix.library.compatdata
            let expected = prefix.library.root.resolvingSymlinksInPath()
                .appending(path: "steamapps/compatdata/\(plan.appID)")
            var info = stat()
            guard prefix.appID == String(plan.appID), prefix.folder == nil,
                  prefix.root.resolvingSymlinksInPath().standardizedFileURL == expected.standardizedFileURL,
                  lstat(parent.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(),
                  lstat(prefix.root.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid()
            else {
                throw StepFailure(step: String(localized: "Delete prefix"),
                                  detail: String(localized: "The game's prefix is not an owned directory in its Steam library."))
            }
            try PrefixTools.delete(prefix)
        }
        return true
    }

    private static func manifest(_ appID: Int, in library: URL) -> URL {
        library.appending(path: "steamapps/appmanifest_\(appID).acf")
    }
}
