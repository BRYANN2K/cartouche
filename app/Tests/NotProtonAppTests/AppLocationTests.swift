import AppKit
import Foundation
import Testing

@testable import NotProtonApp

// Task 2.5: Move to Applications. The disk image is real, made and mounted in a
// scratch folder; "Applications" is a scratch folder too, and nothing relaunches.
@Suite("Move to Applications")
@MainActor
struct AppLocationTests {

    @Test("Where Cartouche runs from decides whether it offers to move")
    func classify() {
        let home = URL(filePath: "/Users/player")
        let root = URL(filePath: "/")
        let cases: [(String, URL?, Bool, AppLocation)] = [
            ("/Applications/Cartouche.app", root, false, .applications),
            ("/private/var/folders/xy/T/AppTranslocation/0A1B/d/Cartouche.app", URL(filePath: "/private/var/folders/xy/T/AppTranslocation/0A1B"), true, .translocated),
            ("/Volumes/Cartouche/Cartouche.app", URL(filePath: "/Volumes/Cartouche"), true, .diskImage),
            ("/Users/player/Downloads/Cartouche.app", root, false, .downloads),
            ("/Users/player/Downloads/Cartouche 2/Cartouche.app", root, false, .downloads),
            // A disk the user keeps apps on, a build folder: left alone
            ("/Volumes/Games SSD/Apps/Cartouche.app", URL(filePath: "/Volumes/Games SSD"), false, .elsewhere),
            ("/Users/player/Code/Cartouche/out/Cartouche.app", root, false, .elsewhere),
            ("/Users/player/Applications/Cartouche.app", root, false, .elsewhere),
        ]
        for (path, volume, readOnly, expected) in cases {
            #expect(AppLocation.of(bundle: URL(filePath: path), volume: volume, readOnly: readOnly, home: home) == expected, "\(path)")
        }
        let offering = [AppLocation.translocated, .diskImage, .downloads, .applications, .elsewhere].filter { $0.offersMove }
        #expect(offering == [.translocated, .diskImage, .downloads])
    }

    @Test("The alert says Move to Applications, with Move and Quit")
    func alert() {
        let alert = MoveToApplications.alert(.diskImage)
        #expect(alert.messageText == "Move to Applications")
        #expect(alert.buttons.map(\.title) == ["Move", "Quit"])
        #expect(alert.informativeText.contains("disk image"))
        #expect(MoveToApplications.alert(.downloads).informativeText.contains("Downloads"))

        // The alert as macOS draws it, without showing it
        if let folder = ProcessInfo.processInfo.environment["CARTOUCHE_SNAPSHOTS"] {
            useCartoucheIcon()
            for dark in [false, true] {
                let alert = MoveToApplications.alert(.diskImage)
                alert.window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                alert.layout()
                guard let view = alert.window.contentView,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                let url = URL(filePath: folder).appending(path: "move-to-applications-\(dark ? "dark" : "light").png")
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
            }
        }
    }

    // A small Cartouche.app on a compressed disk image, mounted read-only like a download
    struct MountedImage {
        let work: URL
        let mount: URL
        var app: URL { mount.appending(path: "Cartouche.app") }

        init() throws {
            work = try scratchDirectory("dmg-move")
            let source = work.appending(path: "source/Cartouche.app/Contents/MacOS")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: URL(filePath: "/usr/bin/true"), to: source.appending(path: "Cartouche"))
            let image = work.appending(path: "Cartouche.dmg").path(percentEncoded: false)
            try #require(Shell.run("/usr/bin/hdiutil", [
                "create", "-quiet", "-srcfolder", work.appending(path: "source").path(percentEncoded: false),
                "-volname", "Cartouche", "-format", "UDZO", image,
            ]).succeeded)
            mount = work.appending(path: "mount")
            try #require(Shell.run("/usr/bin/hdiutil", [
                "attach", "-quiet", "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", mount.path(percentEncoded: false), image,
            ]).succeeded)
        }

        func remove() {
            _ = try? Shell.run("/usr/bin/hdiutil", ["detach", "-quiet", "-force", mount.path(percentEncoded: false)])
            try? FileManager.default.removeItem(at: work)
        }

        var location: AppLocation {
            let values = try? app.resourceValues(forKeys: [.volumeURLKey, .volumeIsReadOnlyKey])
            return AppLocation.of(bundle: app, volume: values?.volume, readOnly: values?.volumeIsReadOnly ?? false)
        }
    }

    @Test("Opened from the mounted disk image: Move copies it to Applications and relaunches from there")
    func moveFromDiskImage() throws {
        let image = try MountedImage()
        defer { image.remove() }
        #expect(image.location == .diskImage)

        let applications = image.work.appending(path: "Applications")
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
        var relaunched: [URL] = []
        var asked: [AppLocation] = []
        var quits = 0
        let mover = AppMover(destination: applications.appending(path: "Cartouche.app"), relauncher: { relaunched.append($0) })

        let goesOn = MoveToApplications.check(
            location: image.location, mover: mover, ask: { asked.append($0); return .move }, quit: { quits += 1 },
            bundle: image.app)

        #expect(!goesOn, "onboarding does not start from the disk image")
        #expect(asked == [.diskImage])
        #expect(relaunched == [applications.appending(path: "Cartouche.app")])
        #expect(quits == 0)
        #expect(FileManager.contentsEqual(image.app.appending(path: "Contents/MacOS/Cartouche"),
                                          applications.appending(path: "Cartouche.app/Contents/MacOS/Cartouche")))
        // Nothing is left half-copied next to it
        #expect(try FileManager.default.contentsOfDirectory(atPath: applications.path(percentEncoded: false)) == ["Cartouche.app"])
    }

    @Test("An older copy in Applications is replaced")
    func replacesOlderCopy() throws {
        let image = try MountedImage()
        defer { image.remove() }
        let destination = image.work.appending(path: "Applications/Cartouche.app")
        try FileManager.default.createDirectory(at: destination.appending(path: "Contents/MacOS"), withIntermediateDirectories: true)
        try Data("old".utf8).write(to: destination.appending(path: "Contents/MacOS/Cartouche"))

        try AppMover(destination: destination, relauncher: { _ in }).move(image.app)

        #expect(FileManager.contentsEqual(image.app.appending(path: "Contents/MacOS/Cartouche"),
                                          destination.appending(path: "Contents/MacOS/Cartouche")))
    }

    @Test("Quit leaves everything as it was")
    func quit() throws {
        let image = try MountedImage()
        defer { image.remove() }
        let destination = image.work.appending(path: "Applications/Cartouche.app")
        var relaunched = 0
        var quits = 0
        let goesOn = MoveToApplications.check(
            location: .diskImage, mover: AppMover(destination: destination, relauncher: { _ in relaunched += 1 }),
            ask: { _ in .quit }, quit: { quits += 1 }, bundle: image.app)
        #expect(!goesOn)
        #expect(quits == 1)
        #expect(relaunched == 0)
        #expect(!FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)))
    }

    @Test("From Applications or a build folder nothing is asked")
    func nothingAsked() {
        for location in [AppLocation.applications, .elsewhere] {
            var asked = 0
            let goesOn = MoveToApplications.check(location: location, ask: { _ in asked += 1; return .quit }, quit: {})
            #expect(goesOn)
            #expect(asked == 0)
        }
    }
}

extension FileManager {
    static func contentsEqual(_ a: URL, _ b: URL) -> Bool {
        FileManager.default.contentsEqual(atPath: a.path(percentEncoded: false), andPath: b.path(percentEncoded: false))
    }
}
