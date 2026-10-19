// Before onboarding: Cartouche opened from the disk image, from Downloads or
// from a translocated copy offers to move itself to /Applications and relaunch
// from there, since permissions and updates are tied to that location.

import AppKit
import Foundation

enum AppLocation: Equatable, Sendable {
    case applications
    // A copy macOS runs from a random read-only path, because it was opened in place after a download
    case translocated
    case diskImage
    case downloads
    // Anywhere else, such as a build folder or ~/Applications: left alone
    case elsewhere

    var offersMove: Bool {
        switch self {
        case .translocated, .diskImage, .downloads: true
        case .applications, .elsewhere: false
        }
    }

    // `volume` is the root of the volume the bundle is on. A disk image mounts read-only;
    // another disk the user keeps apps on does not.
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

struct AppMover {
    var destination = URL(filePath: "/Applications/Cartouche.app")
    var relauncher: @MainActor (URL) -> Void = { LiveRelauncher(bundle: $0).relaunch() }

    struct Failed: LocalizedError {
        let errorDescription: String?
    }

    // Copies the bundle into place, keeping a copy that is already there until the new one is in
    func move(_ bundle: URL) throws {
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
        if fm.fileExists(atPath: destination.path(percentEncoded: false)) {
            _ = try fm.replaceItemAt(destination, withItemAt: staging)
        } else {
            try fm.moveItem(at: staging, to: destination)
        }
    }

    @MainActor
    func moveAndRelaunch(_ bundle: URL) throws {
        try move(bundle)
        AppLog.note("moved to \(destination.path(percentEncoded: false)), relaunching")
        relauncher(destination)
    }
}

// The alert, shown before anything else at launch
@MainActor
enum MoveToApplications {
    enum Choice: Equatable {
        case move
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

    // True when Cartouche goes on starting here
    static func check(location: AppLocation = .current, mover: AppMover = AppMover(),
                      ask: @MainActor (AppLocation) -> Choice = ask, quit: @MainActor () -> Void = { NSApp.terminate(nil) },
                      bundle: URL = Bundle.main.bundleURL) -> Bool {
        guard location.offersMove else { return true }
        AppLog.note("running from \(bundle.path(percentEncoded: false)), offering to move")
        switch ask(location) {
        case .move:
            do {
                try mover.moveAndRelaunch(bundle)
            } catch {
                let alert = NSAlert()
                alert.messageText = String(localized: "Cartouche couldn’t move itself")
                alert.informativeText = error.localizedDescription
                alert.runModal()
                quit()
            }
        case .quit:
            quit()
        }
        return false
    }
}
