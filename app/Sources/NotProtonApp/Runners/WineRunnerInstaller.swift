// Downloaded Wine checked against its pin; nothing is unpacked before the SHA-256 matches.

import Foundation

enum WineRunnerInstaller {

    static let step = String(localized: "Install runner")
    static let damaged = String(localized: "The download was damaged. Try again.")

    // Hashes taken at install time, so later damage can be named file by file
    struct Receipt: Sendable, Equatable, Codable {
        let id: String
        let archiveSHA256: String
        let files: [String: String]
        // The manifest's loader path inside the build; nil in receipts written before it
        var loader: String? = nil
    }

    static let receiptName = ".cartouche-runner.json"

    static var downloads: URL {
        SupportPaths.home.appending(path: "Library/Caches/\(SupportPaths.supportDirName)/runners")
    }

    static let session = PinnedDownload.session(deadline: 2 * 60 * 60)

    static func folder(for id: String, runners: URL = SupportPaths.runners) -> URL {
        runners.appending(path: id)
    }

    // New installs use the id as the folder name; older ones added a wine- prefix
    private static func candidates(for id: String, runners: URL) -> [URL] {
        [folder(for: id, runners: runners), runners.appending(path: "wine-\(id)")]
    }

    static func installedFolder(for id: String, runners: URL = SupportPaths.runners) -> URL? {
        candidates(for: id, runners: runners).first {
            FileManager.default.fileExists(
                atPath: $0.appending(path: receiptName).path(percentEncoded: false))
        }
    }

    static func dir(for id: String, runners: URL = SupportPaths.runners) -> URL {
        candidates(for: id, runners: runners).first {
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: $0.path(percentEncoded: false), isDirectory: &isDir)
                && isDir.boolValue
        } ?? folder(for: id, runners: runners)
    }

    static func receipt(for id: String, runners: URL = SupportPaths.runners) -> Receipt? {
        guard let folder = installedFolder(for: id, runners: runners) else { return nil }
        let file = folder.appending(path: receiptName)
        let receipt = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Receipt.self, from: $0) }
        return receipt?.id == id ? receipt : nil
    }

    static func isInstalled(_ id: String, runners: URL = SupportPaths.runners) -> Bool {
        receipt(for: id, runners: runners) != nil
    }

    // The files whose hashes the receipt keeps: what starts Wine and what Steam's hooks patch
    static func watchedFiles(loader: String) -> [String] {
        [loader, "bin/wineserver"] + WineArch.allCases.map { "lib/wine/\($0.rawValue)/ntdll.dll" }
    }

    static func verify(_ id: String, runners: URL = SupportPaths.runners) -> [String] {
        guard let root = installedFolder(for: id, runners: runners),
              let receipt = receipt(for: id, runners: runners) else { return [] }
        return receipt.files.keys.sorted().compactMap { path in
            Digest.sha256IfPresent(root.appending(path: path)) == receipt.files[path]
                ? nil : String(localized: "\(path) changed since it was installed.")
        }
    }

    @discardableResult
    static func install(
        _ build: RunnerManifest.Build,
        runners: URL = SupportPaths.runners,
        downloads: URL = WineRunnerInstaller.downloads,
        session: URLSession = WineRunnerInstaller.session
    ) async throws -> Receipt {
        // A pending placeholder pins nothing: refuse before any download rather than after it.
        guard build.isPinned else {
            throw StepFailure(step: step, detail: String(localized: "\(build.title) has no published archive yet."))
        }
        let archive = try await PinnedDownload.obtain(
            build.url, sha256: build.sha256, size: build.size,
            into: downloads, step: step, from: "GitHub", session: session)
        defer { try? FileManager.default.removeItem(at: archive) }
        // A swapped archive is checked again before it is unpacked
        let extras = await QAEnvironment.extraHashes(session: session)
        return try unpack(archive, build: build, runners: runners, extraHashes: extras)
    }

    static func unpack(
        _ archive: URL, build: RunnerManifest.Build, runners: URL, extraHashes: Set<String> = []
    ) throws -> Receipt {
        let fm = FileManager.default
        // A file swapped since the download was checked is not unpacked either
        guard let archiveHash = Digest.sha256IfPresent(archive),
              archiveHash == build.sha256 || extraHashes.contains(archiveHash) else {
            try? fm.removeItem(at: archive)
            throw StepFailure(step: step, detail: damaged)
        }
        let target = folder(for: build.id, runners: runners)
        let staging = runners.appending(path: ".\(target.lastPathComponent).new")
        try? fm.removeItem(at: staging)
        defer { try? fm.removeItem(at: staging) }
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        // bsdtar refuses absolute paths and .. in entries unless told otherwise
        try Shell.check("/usr/bin/tar", ["-xf", archive.path(percentEncoded: false), "-C", staging.path(percentEncoded: false)])

        let root = staging.appending(path: build.root)
        let loader = root.appending(path: build.loader)
        guard fm.isExecutableFile(atPath: loader.path(percentEncoded: false)) else {
            throw StepFailure(step: step, detail: String(localized: "The download of \(build.title) has no Wine at \(build.loader)."))
        }

        var files: [String: String] = [:]
        for path in watchedFiles(loader: build.loader) {
            if let hash = Digest.sha256IfPresent(root.appending(path: path)) { files[path] = hash }
        }
        let receipt = Receipt(id: build.id, archiveSHA256: build.sha256, files: files, loader: build.loader)
        try JSONEncoder().encode(receipt).write(to: root.appending(path: receiptName))

        try swapIn(root, at: target)
        return receipt
    }

    static func remove(_ id: String, runners: URL = SupportPaths.runners) throws {
        for target in candidates(for: id, runners: runners)
        where FileManager.default.fileExists(atPath: target.path(percentEncoded: false)) {
            try WriteRefused.catching(target.path(percentEncoded: false)) {
                try FileManager.default.removeItem(at: target)
            }
        }
    }
}
