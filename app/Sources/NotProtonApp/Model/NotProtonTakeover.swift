import CartoucheIdentity
import Foundation

// Taking over a Steam that NotProton injects, after the user asked to replace it.
// At the fork point NotProton's installer puts exactly one file inside Steam.app —
// its dylib — and edits the bundle's LSEnvironment. Its app and its Application
// Support folder are its own and are never touched; its plist backup is only read.
enum NotProtonTakeover {
    static let step = SteamInstaller.step

    // From the fork point's DeploymentContent.files: the only destination inside the
    // bundle is Contents/MacOS/notproton.dylib. Never delete anything else.
    static func bundleContents(in app: URL) -> [URL] {
        [app.appending(path: "Contents/MacOS/\(SteamBundle.otherDylibName)")]
    }

    // NotProton keeps its untouched copy of the plist in its own data folder
    static func plistBackup(in applicationSupport: URL = SupportPaths.applicationSupport) -> URL {
        applicationSupport.appending(
            path: "\(CARTOUCHE_OTHER_STEAM_PREFIX)/\(CARTOUCHE_OTHER_PLIST_BACKUP)"
        )
    }

    // Removes NotProton's insert entries and its files from the bundle, keeping every
    // other environment key. Removed files go to `holding`, so `restore` can put the
    // bundle back exactly as it was. The caller reverts the plist bytes itself.
    static func strip(
        from app: URL,
        holding: URL,
        applicationSupport: URL = SupportPaths.applicationSupport
    ) throws {
        let files = FileManager.default
        let plist = app.appending(path: "Contents/Info.plist")
        guard let dict = SteamBundle.readInfoPlist(at: plist) else {
            throw StepFailure(
                step: step,
                detail: String(localized: "\(plist.path(percentEncoded: false)) could not be read as a property list.")
            )
        }

        let backup = SteamBundle.readInfoPlist(at: plistBackup(in: applicationSupport))
        let restored = backup.map { reverted(to: $0, keeping: dict) } ?? removingInsert(from: dict)
        try SteamBundle.writeInfoPlist(restored, at: plist)

        for source in bundleContents(in: app) {
            guard files.fileExists(atPath: source.path(percentEncoded: false)) else { continue }
            let held = holding.appending(path: source.lastPathComponent)
            try files.createDirectory(at: holding, withIntermediateDirectories: true)
            try WriteRefused.catching(source) { try files.moveItem(at: source, to: held) }
        }
    }

    // NotProton's backup is the bundle plist as it was before it installed. Its own
    // entries win over the current ones, so keys it set leave with it; environment
    // keys added since are kept.
    static func reverted(to backup: [String: Any], keeping current: [String: Any]) -> [String: Any] {
        var restored = backup
        var environment = backup[SteamBundle.environmentKey] as? [String: Any] ?? [:]
        for (key, value) in current[SteamBundle.environmentKey] as? [String: Any] ?? [:]
        where key != SteamBundle.insertKey && key != SteamBundle.controllerBlockKey && environment[key] == nil {
            environment[key] = value
        }
        restored[SteamBundle.environmentKey] = environment.isEmpty ? nil : environment
        return restored
    }

    // Without a backup the insert is filtered instead: NotProton's entries leave,
    // anything else stays, and its controller key goes once nothing loads it.
    static func removingInsert(from dict: [String: Any]) -> [String: Any] {
        var dict = dict
        guard var environment = dict[SteamBundle.environmentKey] as? [String: Any],
              let insert = environment[SteamBundle.insertKey] as? String
        else { return dict }

        let kept = insert.split(separator: ":").map(String.init).filter {
            URL(filePath: $0).lastPathComponent != SteamBundle.otherDylibName
        }
        if kept.isEmpty {
            environment.removeValue(forKey: SteamBundle.insertKey)
            environment.removeValue(forKey: SteamBundle.controllerBlockKey)
        } else {
            environment[SteamBundle.insertKey] = kept.joined(separator: ":")
        }
        dict[SteamBundle.environmentKey] = environment
        return dict
    }

    // Puts the held files back where they were. Runs before the caller writes the
    // prior plist back and re-signs, so the seal covers the restored files.
    static func restore(app: URL, from holding: URL) {
        let files = FileManager.default
        for destination in bundleContents(in: app) {
            let held = holding.appending(path: destination.lastPathComponent)
            guard files.fileExists(atPath: held.path(percentEncoded: false)) else { continue }
            try? files.moveItem(at: held, to: destination)
        }
        try? files.removeItem(at: holding)
    }
}
