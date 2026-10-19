// Downloads a Wine build from the runner manifest, checks it against its pin and
// unpacks it into runners/wine-<id>. Nothing is unpacked before the SHA-256 matches.

import Foundation

enum WineRunnerInstaller {

    static let step = String(localized: "Install runner")
    static let damaged = String(localized: "The download was damaged. Try again.")

    // Hashes taken at install time, so later damage can be named file by file
    struct Receipt: Sendable, Equatable, Codable {
        let id: String
        let archiveSHA256: String
        let files: [String: String]
    }

    static let receiptName = ".cartouche-runner.json"

    static var downloads: URL {
        SupportPaths.home.appending(path: "Library/Caches/\(SupportPaths.supportDirName)/runners")
    }

    static let session = PinnedDownload.session(deadline: 2 * 60 * 60)

    static func folder(for id: String, runners: URL = SupportPaths.runners) -> URL {
        runners.appending(path: "wine-\(id)")
    }

    static func receipt(for id: String, runners: URL = SupportPaths.runners) -> Receipt? {
        let file = folder(for: id, runners: runners).appending(path: receiptName)
        return (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Receipt.self, from: $0) }
    }

    static func isInstalled(_ id: String, runners: URL = SupportPaths.runners) -> Bool {
        receipt(for: id, runners: runners) != nil
    }

    // The files whose hashes the receipt keeps: what starts Wine and what Steam's hooks patch
    static func watchedFiles(loader: String) -> [String] {
        [loader, "bin/wineserver"] + WineArch.allCases.map { "lib/wine/\($0.rawValue)/ntdll.dll" }
    }

    // Files that no longer match the receipt. Empty means ready.
    static func verify(_ id: String, runners: URL = SupportPaths.runners) -> [String] {
        guard let receipt = receipt(for: id, runners: runners) else { return [] }
        let root = folder(for: id, runners: runners)
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
        let extras = await QAEnvironment.extraHashes(session: session)
        let archive = try await download(build, into: downloads, session: session, extraHashes: extras)
        defer { try? FileManager.default.removeItem(at: archive) }
        return try unpack(archive, build: build, runners: runners, extraHashes: extras)
    }

    // The archive, kept only if its size and SHA-256 match the manifest — or, in
    // QA mode, a hash the mock server lists in __pins.json (QAEnvironment)
    static func download(
        _ build: RunnerManifest.Build, into downloads: URL, session: URLSession = WineRunnerInstaller.session,
        extraHashes: Set<String> = []
    ) async throws -> URL {
        let fm = FileManager.default
        let archive = downloads.appending(path: build.archiveName)
        if let onDisk = Digest.sha256IfPresent(archive), onDisk == build.sha256 || extraHashes.contains(onDisk) { return archive }
        try? fm.removeItem(at: archive)

        let body: URL, response: URLResponse
        do {
            (body, response) = try await session.download(from: QAEnvironment.url(build.url))
        } catch {
            AppLog.note("\(build.id): \(build.url.absoluteString) unreachable: \(error.localizedDescription)")
            throw StepFailure(step: step, detail: String(localized: "Cartouche could not download \(build.title). Check your internet connection and try again."))
        }
        defer { try? fm.removeItem(at: body) }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            AppLog.note("\(build.id): \(build.url.absoluteString) answered \(http.statusCode)")
            throw StepFailure(step: step, detail: String(localized: "Cartouche could not download \(build.title). Check your internet connection and try again."))
        }

        let size = (try? fm.attributesOfItem(atPath: body.path(percentEncoded: false))[.size] as? Int64) ?? -1
        let got = try Digest.sha256(of: body)
        guard (size == build.size && got == build.sha256) || extraHashes.contains(got) else {
            AppLog.note("\(build.id): got \(size) bytes with SHA-256 \(got), the pin is \(build.size) bytes, \(build.sha256)")
            throw StepFailure(step: step, detail: damaged)
        }
        try fm.createDirectory(at: downloads, withIntermediateDirectories: true)
        try fm.moveItem(at: body, to: archive)
        return archive
    }

    // Unpacks next to the runners folder and moves the build in only when it is complete
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
        let receipt = Receipt(id: build.id, archiveSHA256: build.sha256, files: files)
        try JSONEncoder().encode(receipt).write(to: root.appending(path: receiptName))

        try? fm.removeItem(at: target)
        try fm.moveItem(at: root, to: target)
        return receipt
    }

    static func remove(_ id: String, runners: URL = SupportPaths.runners) throws {
        let target = folder(for: id, runners: runners)
        guard FileManager.default.fileExists(atPath: target.path(percentEncoded: false)) else { return }
        try WriteRefused.catching(target.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: target)
        }
    }
}
