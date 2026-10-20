
import Foundation

enum PinnedDownload {

    enum Progress: Sendable {
        case reusing
        case fetching(host: String)

        var label: String {
            switch self {
            case .reusing: String(localized: "Preparing")
            case .fetching(let host): String(localized: "Downloading from \(host)")
            }
        }
    }

    static let session = session(deadline: 30 * 60)

    static func session(deadline: TimeInterval, protocols: [AnyClass] = []) -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = deadline
        config.protocolClasses = protocols + (config.protocolClasses ?? [])
        return URLSession(configuration: config)
    }

    static func obtain(
        _ url: URL,
        sha256: String,
        size: Int64? = nil,
        into downloads: URL,
        step: String,
        from source: String,
        session: URLSession = PinnedDownload.session,
        report: @Sendable (Progress) -> Void = { _ in }
    ) async throws -> URL {
        try await obtain(
            file: url.lastPathComponent, sha256: sha256, size: size,
            bases: [url.deletingLastPathComponent()], into: downloads,
            step: step, from: source, session: session, report: report)
    }

    static func obtain(
        file: String,
        sha256: String,
        size: Int64? = nil,
        bases: [URL],
        into downloads: URL,
        step: String,
        from source: String = "Valve",
        session: URLSession = PinnedDownload.session,
        report: @Sendable (Progress) -> Void = { _ in }
    ) async throws -> URL {
        let archive = downloads.appending(path: file)
        // QA mode: the mock's synthetic files cannot match the real pins, so the hashes it lists in __pins.json count too (QAEnvironment)
        let extras = await QAEnvironment.extraHashes(session: session)
        if let onDisk = Digest.sha256IfPresent(archive), onDisk == sha256 || extras.contains(onDisk) {
            report(.reusing)
            return archive
        }
        try? FileManager.default.removeItem(at: archive)

        var refusals: [String] = []
        var kinds: Set<Refusal> = []
        for base in bases.map(QAEnvironment.url) {
            let host = base.host() ?? base.absoluteString
            report(.fetching(host: host))
            let body: URL, response: URLResponse
            do {
                (body, response) = try await session.download(from: base.appending(path: file))
            } catch {
                refusals.append("\(host): \(error.localizedDescription)")
                kinds.insert(.unreachable)
                continue
            }
            defer { try? FileManager.default.removeItem(at: body) }

            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                refusals.append("\(host) answered \(http.statusCode)")
                kinds.insert(.answered)
                continue
            }

            let gotSize = (try? FileManager.default.attributesOfItem(
                atPath: body.path(percentEncoded: false))[.size] as? Int64) ?? -1
            let got = try Digest.sha256(of: body)
            guard (got == sha256 && (size == nil || gotSize == size)) || extras.contains(got) else {
                refusals.append("\(host) served \(got.prefix(16)) (\(gotSize) bytes) rather than \(sha256.prefix(16))")
                kinds.insert(.mismatch)
                continue
            }

            do {
                try FileManager.default.createDirectory(
                    at: downloads, withIntermediateDirectories: true
                )
                try? FileManager.default.removeItem(at: archive)
                try FileManager.default.moveItem(at: body, to: archive)
            } catch {
                throw StepFailure(
                    step: step,
                    detail: String(localized: "\(downloads.path(percentEncoded: false)) could not be written. ")
                        + error.localizedDescription
                )
            }
            return archive
        }

        AppLog.note("\(file) refused by all \(bases.count) hosts: \(refusals.joined(separator: ". "))")
        throw StepFailure(step: step, detail: reason(kinds, from: source))
    }

    private enum Refusal {
        case unreachable
        case mismatch
        case answered
    }

    private static func reason(_ kinds: Set<Refusal>, from source: String) -> String {
        if kinds == [.mismatch] {
            return String(localized: "Something is wrong with the downloaded files. Please check for a Cartouche update.")
        }
        if kinds == [.unreachable] {
            return String(localized: "Cartouche could not reach \(source)'s servers. Please check your internet connection and try again.")
        }
        return String(localized: "Cartouche could not download the files it needs from \(source). Please try again later.")
    }
}
