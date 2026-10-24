//// Before onboarding: Cartouche opened from the disk image, Downloads or a translocated copy offers to move itself
//// to /Applications and relaunch, since permissions and updates are tied to that location.

import AppKit
import Foundation

enum AppLocation: Equatable, Sendable {
    case applications
    // A copy macOS runs from a random read-only path, because it was opened in place after a download
    case translocated
    case diskImage
    case downloads
    case elsewhere

    var offersMove: Bool {
        switch self {
        case .translocated, .diskImage, .downloads: true
        case .applications, .elsewhere: false
        }
    }

    static func of(bundle: URL, volume: URL?, readOnly: Bool, home: URL = SupportPaths.home) -> AppLocation {
        let path = bundle.standardizedFileURL.path(percentEncoded: false)
        if path.contains("/AppTranslocation/") { return .translocated }
        if path.hasPrefix("/Applications/") { return .applications }
        if readOnly, let volume, volume.standardizedFileURL.path(percentEncoded: false) != "/" { return .diskImage }
        let downloads = home.appending(path: "Downloads").standardizedFileURL.path(percentEncoded: false)
        if path.hasPrefix(downloads + "/") { return .downloads }
        return .elsewhere
    }

    static var current: AppLocation {
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app" else { return .elsewhere }
        let values = try? bundle.resourceValues(forKeys: [.volumeURLKey, .volumeIsReadOnlyKey])
        return of(bundle: bundle, volume: values?.volume, readOnly: values?.volumeIsReadOnly ?? false)
    }
}

struct AppBundleVersion: Equatable, Sendable {
    let short: String
    let build: String

    var display: String { build.isEmpty || build == short ? short : "\(short) (\(build))" }

    static func of(_ app: URL) -> AppBundleVersion? {
        guard let info = NSDictionary(contentsOf: app.appending(path: "Contents/Info.plist")) else { return nil }
        let short = info["CFBundleShortVersionString"] as? String ?? ""
        let build = info["CFBundleVersion"] as? String ?? ""
        guard !short.isEmpty || !build.isEmpty else { return nil }
        return AppBundleVersion(short: short, build: build)
    }

    func isNewer(than other: AppBundleVersion) -> Bool {
        switch short.compare(other.short, options: .numeric) {
        case .orderedDescending: true
        case .orderedAscending: false
        case .orderedSame: build.compare(other.build, options: .numeric) == .orderedDescending
        }
    }

    // The installed copy's and this copy's versions, when the installed one is newer
    static func newer(installed: URL, than bundle: URL) -> (installed: String, current: String)? {
        guard let there = of(installed), let here = of(bundle), there.isNewer(than: here) else { return nil }
        return (there.display, here.display)
    }
}

struct AppMover {
    var destination = URL(filePath: "/Applications/Cartouche.app")
    var relauncher: @MainActor (URL) -> Void = { _ = LiveRelauncher(bundle: $0).relaunch() }
    var destinationRunning: @MainActor (URL) -> Bool = { destination in
        let id = Bundle.main.bundleIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: id ?? "")
            .contains { $0.bundleURL?.standardizedFileURL == destination.standardizedFileURL }
    }

    struct Failed: LocalizedError {
        let errorDescription: String?
    }

    static func move(_ bundle: URL, to destination: URL) throws {
        // ditto and xattr wait on processes: a call on the main actor traps in debug builds
        assert(!Thread.isMainThread, "AppMover.move waits on processes; it never runs on the main actor")
        let fm = FileManager.default
        let folder = destination.deletingLastPathComponent()
        let staging = folder.appending(path: ".Cartouche-\(UUID().uuidString).app")
        defer { try? fm.removeItem(at: staging) }
        let copy = Process()
        copy.executableURL = URL(filePath: "/usr/bin/ditto")
        copy.arguments = [bundle.path(percentEncoded: false), staging.path(percentEncoded: false)]
        copy.standardError = FileHandle.nullDevice
        try copy.run()
        copy.waitUntilExit()
        guard copy.terminationStatus == 0 else {
            throw Failed(errorDescription: String(localized: "Cartouche couldn’t copy itself to \(folder.path(percentEncoded: false)). Drag it to Applications in Finder."))
        }
        // A ditto copy of a quarantined or translocated app stays quarantined; the moved copy is not
        _ = try? Shell.check("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staging.path(percentEncoded: false)])
        if fm.fileExists(atPath: destination.path(percentEncoded: false)) {
            _ = try fm.replaceItemAt(destination, withItemAt: staging)
        } else {
            try fm.moveItem(at: staging, to: destination)
        }
    }

    @MainActor
    func moveAndRelaunch(_ bundle: URL) async throws {
        guard !destinationRunning(destination) else {
            throw Failed(errorDescription: String(localized: "Cartouche is already open from \(destination.path(percentEncoded: false)). Quit that copy, then move Cartouche again."))
        }
        // ditto's copy waits on a process: it never runs on the main actor
        let destination = destination
        try await Task.detached { try Self.move(bundle, to: destination) }.value
        AppLog.note("moved to \(destination.path(percentEncoded: false)), relaunching")
        relauncher(destination)
    }
}

@MainActor
enum MoveToApplications {
    enum Choice: Equatable {
        case move
        case quit
    }

    enum ReplaceChoice: Equatable {
        case openInstalled
        case replace
        case quit
    }

    static func message(_ location: AppLocation) -> String {
        switch location {
        case .diskImage:
            String(localized: "Cartouche is running from the disk image. Move it to Applications, so permissions and updates stay with it. It relaunches from there.")
        case .downloads, .translocated:
            String(localized: "Cartouche is running from Downloads. Move it to Applications, so permissions and updates stay with it. It relaunches from there.")
        case .applications, .elsewhere:
            ""
        }
    }

    static func alert(_ location: AppLocation) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = String(localized: "Move to Applications")
        alert.informativeText = message(location)
        alert.addButton(withTitle: String(localized: "Move"))
        alert.addButton(withTitle: String(localized: "Quit"))
        return alert
    }

    static func ask(_ location: AppLocation) -> Choice {
        alert(location).runModal() == .alertFirstButtonReturn ? .move : .quit
    }

    static func askReplace(installed: String, current: String) -> ReplaceChoice {
        let alert = NSAlert()
        alert.messageText = String(localized: "A newer Cartouche is in Applications")
        alert.informativeText = String(localized: "Applications has Cartouche \(installed). This copy is \(current). Moving it would replace the newer version.")
        alert.addButton(withTitle: String(localized: "Open Newer Copy"))
        alert.addButton(withTitle: String(localized: "Replace"))
        alert.addButton(withTitle: String(localized: "Quit"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .openInstalled
        case .alertSecondButtonReturn: return .replace
        default: return .quit
        }
    }

    static func check(location: AppLocation = .current, mover: AppMover = AppMover(),
                      ask: @MainActor (AppLocation) -> Choice = ask,
                      askReplace: @escaping @MainActor (String, String) -> ReplaceChoice = { askReplace(installed: $0, current: $1) },
                      quit: @escaping @MainActor () -> Void = { NSApp.terminate(nil) },
                      bundle: URL = Bundle.main.bundleURL) -> Bool {
        guard location.offersMove else { return true }
        AppLog.note("running from \(bundle.path(percentEncoded: false)), offering to move")
        switch ask(location) {
        case .move:
            // The copy waits on a process: it runs after check returns, off the
            // main actor, and the relaunch or the error alert comes back to it.
            Task {
                let destination = mover.destination
                let newer = await Task.detached { AppBundleVersion.newer(installed: destination, than: bundle) }.value
                if let newer {
                    switch askReplace(newer.installed, newer.current) {
                    case .openInstalled:
                        mover.relauncher(destination)
                        return
                    case .quit:
                        quit()
                        return
                    case .replace:
                        break
                    }
                }
                do {
                    try await mover.moveAndRelaunch(bundle)
                } catch {
                    let alert = NSAlert()
                    alert.messageText = String(localized: "Cartouche couldn’t move itself")
                    alert.informativeText = error.localizedDescription
                    alert.runModal()
                    quit()
                }
            }
        case .quit:
            quit()
        }
        return false
    }
}
