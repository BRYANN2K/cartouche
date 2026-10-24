import Foundation
import RetroArchKit

struct EmulatorManifest: PinnedManifest {
    static let format = 1
    static let resource = "emulators"
    var format: Int
    var downloads: [Download]

    struct Download: Codable, Equatable, Sendable {
        var id: String
        var version: String
        var url: URL
        var sha256: String
        var archive: String
    }

    func problems() -> [String] {
        var problems: [String] = []
        if format != Self.format { problems.append("Unsupported emulator manifest format") }
        if Set(downloads.map(\.id)).count != downloads.count { problems.append("Duplicate emulator download") }
        for download in downloads {
            if EmulatorCatalog.emulator(download.id) == nil || download.version.isEmpty
                || download.url.scheme != "https" || !Self.isSHA256(download.sha256)
                || !["zip", "tar", "dmg"].contains(download.archive) {
                problems.append("Invalid emulator download: \(download.id)")
            }
        }
        return problems
    }
}

struct EmulatorInstaller: Sendable {
    var applications = SupportPaths.home.appending(path: "Applications", directoryHint: .isDirectory)
    var downloads = SupportPaths.home.appending(path: "Library/Caches/Cartouche/emulators", directoryHint: .isDirectory)
    var manifest: @Sendable () throws -> EmulatorManifest = { try .bundled() }
    var session: URLSession = PinnedDownload.session
    var verify: @Sendable (URL) throws -> Void = { app in
        try Shell.check("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
    }

    func install(_ emulator: StandaloneEmulator) async throws -> InstalledEmulator {
        if let found = await Task.detached(operation: { EmulatorDetector(folders: [applications]).installed().first { $0.id == emulator.id } }).value {
            return found
        }
        guard let spec = try manifest().downloads.first(where: { $0.id == emulator.id }) else {
            throw StepFailure(step: String(localized: "Install \(emulator.name)"),
                              detail: String(localized: "No automatic download is available for \(emulator.name). Choose another emulator in Settings > Consoles."))
        }
        let archive = try await PinnedDownload.obtain(spec.url, sha256: spec.sha256, into: downloads,
            step: String(localized: "Download \(emulator.name)"), from: emulator.name, session: session)
        try Task.checkCancellation()
        let installer = self
        let work = Task.detached { try installer.unpack(archive, spec: spec, emulator: emulator) }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }

    func unpack(_ archive: URL, spec: EmulatorManifest.Download, emulator: StandaloneEmulator) throws -> InstalledEmulator {
        let fm = FileManager.default
        try fm.createDirectory(at: applications, withIntermediateDirectories: true)
        let work = applications.appending(path: ".cartouche-install-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let expanded = work.appending(path: "expanded", directoryHint: .isDirectory)
        try fm.createDirectory(at: expanded, withIntermediateDirectories: true)
        let mounted = spec.archive == "dmg"
        if mounted {
            try Shell.check("/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", "-mountpoint", expanded.path, archive.path])
        }
        defer { if mounted { _ = try? Shell.check("/usr/bin/hdiutil", ["detach", expanded.path]) } }
        if spec.archive == "zip" {
            try Shell.check("/usr/bin/ditto", ["-x", "-k", archive.path, expanded.path])
        } else if spec.archive == "tar" {
            try Shell.check("/usr/bin/tar", ["-xf", archive.path, "-C", expanded.path])
        }
        try Task.checkCancellation()
        guard let candidate = Self.find(emulator.id, in: expanded) else {
            throw StepFailure(step: String(localized: "Install \(emulator.name)"),
                              detail: String(localized: "The archive does not contain a working \(emulator.name) application."))
        }
        try verify(candidate.app)
        let prepared = work.appending(path: candidate.app.lastPathComponent)
        try Shell.check("/usr/bin/ditto", [candidate.app.path, prepared.path])
        try verify(prepared)
        try Task.checkCancellation()
        let target = applications.appending(path: candidate.app.lastPathComponent)
        guard !fm.fileExists(atPath: target.path) else {
            if let existing = EmulatorDetector.read(target), existing.id == emulator.id { return existing }
            throw StepFailure(step: String(localized: "Install \(emulator.name)"),
                              detail: String(localized: "\(target.lastPathComponent) already exists and could not be used."))
        }
        try fm.moveItem(at: prepared, to: target)
        guard let installed = EmulatorDetector.read(target), installed.id == emulator.id else {
            throw StepFailure(step: String(localized: "Install \(emulator.name)"),
                              detail: String(localized: "The installed emulator could not be opened."))
        }
        return installed
    }

    static func find(_ id: String, in folder: URL) -> InstalledEmulator? {
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil,
                                                 options: [.skipsHiddenFiles, .skipsPackageDescendants])
        while let file = files?.nextObject() as? URL {
            if file.pathExtension == "app", let found = EmulatorDetector.read(file), found.id == id { return found }
        }
        return nil
    }
}
