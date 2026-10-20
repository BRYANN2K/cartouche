// DXMT and DXVK pinned by size and SHA-256; nothing reaches a prefix before the archive matches its pin. D3DMetal is never downloaded.

import Foundation

struct BackendManifest: PinnedManifest {

    typealias Invalid = ManifestInvalid
    static let format = 1
    static let resource = "backends"

    struct Pin: Sendable, Equatable, Codable, Identifiable {
        let backend: GraphicsBackend
        let name: String
        let version: String
        let license: String
        let url: URL
        let size: Int64
        let sha256: String
        let files: [String]

        var id: String { backend.rawValue }
        var title: String { "\(name) \(version)" }
        var archiveName: String { url.lastPathComponent }
    }

    let format: Int
    let revision: Int
    let backends: [Pin]

    func pin(_ backend: GraphicsBackend) -> Pin? { backends.first { $0.backend == backend } }

    static let downloadable: Set<GraphicsBackend> = [.dxmt, .dxvk]

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
            if !Self.isSHA256(pin.sha256) { found.append("\(at): \(pin.sha256) is not a SHA-256") }
            if pin.files.isEmpty { found.append("\(at): no files") }
            for path in pin.files where !Self.isInside(path) || !BackendInstaller.folders.contains(where: { path.hasPrefix($0 + "/") }) {
                found.append("\(at): \(path) is outside \(BackendInstaller.folders.joined(separator: ", "))")
            }
        }
        return found
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

    @discardableResult
    static func install(
        _ pin: BackendManifest.Pin, backends: URL = folder, downloads: URL = BackendInstaller.downloads,
        session: URLSession = PinnedDownload.session
    ) async throws -> Receipt {
        let archive = try await PinnedDownload.obtain(
            pin.url, sha256: pin.sha256, size: pin.size,
            into: downloads, step: step, from: "GitHub", session: session)
        defer { try? FileManager.default.removeItem(at: archive) }
        // A swapped archive is checked again before it is unpacked
        let extras = await QAEnvironment.extraHashes(session: session)
        return try unpack(archive, pin: pin, backends: backends, extraHashes: extras)
    }

    static func unpack(
        _ archive: URL, pin: BackendManifest.Pin, backends: URL, extraHashes: Set<String> = []
    ) throws -> Receipt {
        let fm = FileManager.default
        // A file swapped since the download was checked is not unpacked either
        guard let archiveHash = Digest.sha256IfPresent(archive),
              archiveHash == pin.sha256 || extraHashes.contains(archiveHash) else {
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

        try swapIn(result, at: target)
        return receipt
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
