// DXMT and DXVK, downloaded from their GitHub releases and pinned by size and SHA-256
// in backends.json. Nothing is unpacked, and so nothing reaches a prefix, before the
// archive matches its pin. D3DMetal is never downloaded: it comes from the user's
// Game Porting Toolkit or CrossOver.

import Foundation

struct BackendManifest: Sendable, Equatable, Codable {

    static let format = 1

    struct Pin: Sendable, Equatable, Codable, Identifiable {
        let backend: GraphicsBackend
        // Product name, not translated
        let name: String
        let version: String
        let license: String
        let url: URL
        let size: Int64
        let sha256: String
        // What the archive must hold once unpacked, under the folders the run script reads
        let files: [String]

        var id: String { backend.rawValue }
        var title: String { "\(name) \(version)" }
        var archiveName: String { url.lastPathComponent }
    }

    let format: Int
    let revision: Int
    let backends: [Pin]

    func pin(_ backend: GraphicsBackend) -> Pin? { backends.first { $0.backend == backend } }

    struct Invalid: Error, Equatable, CustomStringConvertible {
        let problems: [String]
        var description: String { problems.joined(separator: "; ") }
    }

    // The only backends Cartouche may download
    static let downloadable: Set<GraphicsBackend> = [.dxmt, .dxvk]

    static func read(_ data: Data) throws -> BackendManifest {
        let manifest = try JSONDecoder().decode(BackendManifest.self, from: data)
        let problems = manifest.problems()
        guard problems.isEmpty else { throw Invalid(problems: problems) }
        return manifest
    }

    func problems() -> [String] {
        var found: [String] = []
        if format != Self.format { found.append("format \(format) is not \(Self.format)") }
        var seen: Set<GraphicsBackend> = []
        for pin in backends {
            let at = "backend \(pin.backend.rawValue)"
            if !seen.insert(pin.backend).inserted { found.append("\(at) is listed twice") }
            if !Self.downloadable.contains(pin.backend) { found.append("\(at) is not downloadable") }
            if pin.url.scheme != "https" || !RunnerManifest.allowedHosts.contains(pin.url.host() ?? "") {
                found.append("\(at): \(pin.url.absoluteString) is not an https URL on github.com")
            }
            if pin.size <= 0 { found.append("\(at): size \(pin.size)") }
            if !RunnerManifest.isSHA256(pin.sha256) { found.append("\(at): \(pin.sha256) is not a SHA-256") }
            if pin.files.isEmpty { found.append("\(at): no files") }
            for path in pin.files where !RunnerManifest.isInside(path) || !BackendInstaller.folders.contains(where: { path.hasPrefix($0 + "/") }) {
                found.append("\(at): \(path) is outside \(BackendInstaller.folders.joined(separator: ", "))")
            }
        }
        return found
    }

    static func bundled() throws -> BackendManifest {
        guard let url = Bundle.module.url(forResource: "backends", withExtension: "json") else {
            throw Invalid(problems: ["backends.json is not in the app"])
        }
        return try read(Data(contentsOf: url))
    }

    static func current() -> BackendManifest {
        do {
            return try bundled()
        } catch {
            AppLog.note("backends.json in the app is unreadable: \(error)")
            return BackendManifest(format: format, revision: 0, backends: [])
        }
    }
}

enum BackendInstaller {

    static let step = String(localized: "Install graphics backend")

    // The folders the run script adds to WINEDLLPATH, in backends/<backend>/
    static let folders = ["x86_64-windows", "i386-windows", "x86_64-unix"]
    // Other names releases use for the same folders
    static let aliases = ["x64": "x86_64-windows", "x32": "i386-windows"]

    struct Receipt: Sendable, Equatable, Codable {
        let backend: GraphicsBackend
        let version: String
        let archiveSHA256: String
        let files: [String: String]
    }

    static let receiptName = ".cartouche-backend.json"

    static var folder: URL { SupportPaths.backends }

    static var downloads: URL {
        SupportPaths.home.appending(path: "Library/Caches/\(SupportPaths.supportDirName)/backends")
    }

    static func folder(for backend: GraphicsBackend, in backends: URL = folder) -> URL {
        backends.appending(path: backend.rawValue)
    }

    static func receipt(for backend: GraphicsBackend, in backends: URL = folder) -> Receipt? {
        let file = folder(for: backend, in: backends).appending(path: receiptName)
        return (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Receipt.self, from: $0) }
    }

    static func installed(in backends: URL = folder) -> [Receipt] {
        BackendManifest.downloadable.sorted { $0.rawValue < $1.rawValue }.compactMap { receipt(for: $0, in: backends) }
    }

    // Files that no longer match the receipt. Empty means ready.
    static func verify(_ backend: GraphicsBackend, in backends: URL = folder) -> [String] {
        guard let receipt = receipt(for: backend, in: backends) else { return [] }
        let root = folder(for: backend, in: backends)
        return receipt.files.keys.sorted().compactMap { path in
            Digest.sha256IfPresent(root.appending(path: path)) == receipt.files[path]
                ? nil : String(localized: "\(path) changed since it was installed.")
        }
    }

    @discardableResult
    static func install(
        _ pin: BackendManifest.Pin, backends: URL = folder, downloads: URL = BackendInstaller.downloads,
        session: URLSession = PinnedDownload.session
    ) async throws -> Receipt {
        let archive = try await download(pin, into: downloads, session: session)
        defer { try? FileManager.default.removeItem(at: archive) }
        return try unpack(archive, pin: pin, backends: backends)
    }

    // The archive, kept only if its size and SHA-256 match the pin
    static func download(_ pin: BackendManifest.Pin, into downloads: URL, session: URLSession) async throws -> URL {
        let fm = FileManager.default
        let archive = downloads.appending(path: pin.archiveName)
        if Digest.sha256IfPresent(archive) == pin.sha256 { return archive }
        try? fm.removeItem(at: archive)

        let unreachable = String(localized: "Cartouche could not download \(pin.title). Check your internet connection and try again.")
        let body: URL, response: URLResponse
        do {
            (body, response) = try await session.download(from: pin.url)
        } catch {
            AppLog.note("\(pin.id): \(pin.url.absoluteString) unreachable: \(error.localizedDescription)")
            throw StepFailure(step: step, detail: unreachable)
        }
        defer { try? fm.removeItem(at: body) }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            AppLog.note("\(pin.id): \(pin.url.absoluteString) answered \(http.statusCode)")
            throw StepFailure(step: step, detail: unreachable)
        }
        let size = (try? fm.attributesOfItem(atPath: body.path(percentEncoded: false))[.size] as? Int64) ?? -1
        let got = try Digest.sha256(of: body)
        guard size == pin.size, got == pin.sha256 else {
            AppLog.note("\(pin.id): got \(size) bytes with SHA-256 \(got), the pin is \(pin.size) bytes, \(pin.sha256)")
            throw StepFailure(step: step, detail: WineRunnerInstaller.damaged)
        }
        try fm.createDirectory(at: downloads, withIntermediateDirectories: true)
        try fm.moveItem(at: body, to: archive)
        return archive
    }

    // Unpacks beside the backends folder and moves the result in only when it is complete
    static func unpack(_ archive: URL, pin: BackendManifest.Pin, backends: URL) throws -> Receipt {
        let fm = FileManager.default
        // A file swapped since the download was checked is not unpacked either
        guard Digest.sha256IfPresent(archive) == pin.sha256 else {
            try? fm.removeItem(at: archive)
            throw StepFailure(step: step, detail: WineRunnerInstaller.damaged)
        }
        try fm.createDirectory(at: backends, withIntermediateDirectories: true)
        let target = folder(for: pin.backend, in: backends)
        let staging = backends.appending(path: ".\(pin.backend.rawValue).unpack")
        let result = backends.appending(path: ".\(pin.backend.rawValue).new")
        for scratch in [staging, result] { try? fm.removeItem(at: scratch) }
        defer { for scratch in [staging, result] { try? fm.removeItem(at: scratch) } }
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        try fm.createDirectory(at: result, withIntermediateDirectories: true)

        // bsdtar refuses absolute paths and .. in entries unless told otherwise
        try Shell.check("/usr/bin/tar", ["-xf", archive.path(percentEncoded: false), "-C", staging.path(percentEncoded: false)])

        // Releases put the folders at the top or one level down, under either name
        guard let root = layoutRoot(in: staging) else {
            throw StepFailure(step: step, detail: String(localized: "The download of \(pin.title) does not hold the files Cartouche expects."))
        }
        for (name, normal) in folderNames(in: root) {
            try fm.moveItem(at: root.appending(path: name), to: result.appending(path: normal))
        }
        let missing = pin.files.filter { !fm.fileExists(atPath: result.appending(path: $0).path(percentEncoded: false)) }
        guard missing.isEmpty else {
            AppLog.note("\(pin.id): the archive lacks \(missing.joined(separator: ", "))")
            throw StepFailure(step: step, detail: String(localized: "The download of \(pin.title) does not hold the files Cartouche expects."))
        }

        var files: [String: String] = [:]
        for folder in folders {
            let base = result.appending(path: folder)
            let entries = (try? fm.contentsOfDirectory(atPath: base.path(percentEncoded: false))) ?? []
            for name in entries.sorted() {
                let file = base.appending(path: name)
                var isDirectory: ObjCBool = false
                guard fm.fileExists(atPath: file.path(percentEncoded: false), isDirectory: &isDirectory), !isDirectory.boolValue
                else { continue }
                files["\(folder)/\(name)"] = try Digest.sha256(of: file)
            }
        }
        let receipt = Receipt(backend: pin.backend, version: pin.version, archiveSHA256: pin.sha256, files: files)
        try JSONEncoder().encode(receipt).write(to: result.appending(path: receiptName))

        try? fm.removeItem(at: target)
        try fm.moveItem(at: result, to: target)
        return receipt
    }

    static func remove(_ backend: GraphicsBackend, in backends: URL = folder) throws {
        let target = folder(for: backend, in: backends)
        guard FileManager.default.fileExists(atPath: target.path(percentEncoded: false)) else { return }
        try WriteRefused.catching(target.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: target)
        }
    }

    // The folder holding x86_64-windows (or x64), at the top or one level down
    private static func layoutRoot(in staging: URL) -> URL? {
        let fm = FileManager.default
        var candidates = [staging]
        let top = (try? fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)) ?? []
        candidates += top.sorted { $0.lastPathComponent < $1.lastPathComponent }
        return candidates.first { candidate in
            ["x86_64-windows", "x64"].contains { fm.fileExists(atPath: candidate.appending(path: $0).path(percentEncoded: false)) }
        }
    }

    // Folder name in the archive to the name the run script reads
    private static func folderNames(in root: URL) -> [(String, String)] {
        let fm = FileManager.default
        var out: [(String, String)] = []
        var taken: Set<String> = []
        for name in folders + aliases.keys.sorted() {
            let normal = aliases[name] ?? name
            guard !taken.contains(normal), fm.fileExists(atPath: root.appending(path: name).path(percentEncoded: false)) else { continue }
            taken.insert(normal)
            out.append((name, normal))
        }
        return out
    }
}
