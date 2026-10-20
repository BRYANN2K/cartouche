// Fetches compat.json.gz at most once a day and keeps the last valid copy, so the library works offline

import Foundation

struct CompatibilityClient: Sendable {

    // The compat-data release of the repository that serves the Sparkle feed, so the repository is named in one place, SUFeedURL in Info.plist
    static var feed: URL? {
        guard let appcast = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String else { return nil }
        return URL(string: appcast).map(QAEnvironment.url).flatMap(feed(fromAppcast:))
    }

    // .../releases/latest/download/appcast.xml -> .../releases/download/compat-data/compat.json.gz
    static func feed(fromAppcast appcast: URL) -> URL? {
        let parts = appcast.pathComponents
        guard let releases = parts.lastIndex(of: "releases"), releases >= 3, releases + 1 < parts.count else { return nil }
        var url = appcast.deletingLastPathComponent()
        for _ in (releases + 1)..<(parts.count - 1) { url.deleteLastPathComponent() }
        return url.appending(path: "download/compat-data/compat.json.gz")
    }

    typealias Fetch = HTTPFetch.Fetch

    let directory: URL
    var feed: URL? = CompatibilityClient.feed
    var fetch: Fetch = HTTPFetch.download(timeout: 30, resourceTimeout: 5 * 60,
                                        userAgent: "Cartouche/\(AppVersion.bundled)")

    var cacheFile: URL { directory.appending(path: "compat.json.gz") }
    var stateFile: URL { directory.appending(path: "fetch-state.json") }

    static var standard: CompatibilityClient {
        CompatibilityClient(directory: SupportPaths.support.appending(path: "compatibility"))
    }

    enum Outcome: Sendable {
        case skipped
        case updated(CompatData)
        case offline
        case unavailable(status: Int)
        case rejected(String)
    }

    private struct State: Codable {
        var lastContact: Date
    }

    func cached(schema: CompatSchema) -> CompatData? {
        guard let data = try? Data(contentsOf: cacheFile) else { return nil }
        do {
            return try CompatData.read(data, schema: schema)
        } catch {
            AppLog.note("compatibility cache unreadable, ignored: \(error)")
            return nil
        }
    }

    func lastContact() -> Date? {
        guard let data = try? Data(contentsOf: stateFile) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(State.self, from: data))?.lastContact
    }

    private func recordContact(_ now: Date) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(State(lastContact: now)) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? atomicReplace(stateFile, with: data, step: "compatibility")
    }

    func refresh(now: Date, schema: CompatSchema) async -> Outcome {
        if let last = lastContact(), now.timeIntervalSince(last) < 24 * 3600, now >= last {
            return .skipped
        }
        guard let feed else { return .unavailable(status: 0) }
        let body: Data, status: Int
        do {
            (body, status) = try await fetch(feed)
        } catch {
            AppLog.note("compatibility data not fetched: \(error.localizedDescription)")
            return .offline
        }
        recordContact(now)
        guard status == 200 else {
            AppLog.note("compatibility data not fetched: HTTP \(status)")
            return .unavailable(status: status)
        }
        let fresh: CompatData
        do {
            fresh = try CompatData.read(body, schema: schema)
        } catch {
            AppLog.note("compatibility download discarded: \(error)")
            return .rejected("\(error)")
        }
        if let current = cached(schema: schema), fresh.generated < current.generated {
            AppLog.note("compatibility download discarded: older than the copy in use")
            return .rejected("older than the copy in use")
        }
        do {
            try atomicReplace(cacheFile, with: body, step: "compatibility")
        } catch {
            AppLog.note("compatibility download not saved: \(error)")
        }
        return .updated(fresh)
    }
}
