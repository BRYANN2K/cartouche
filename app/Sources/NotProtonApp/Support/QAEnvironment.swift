// QA mode (debug builds only): CARTOUCHE_QA_BASE_URL re-points remote fetches and accepts extra sha256s from <base>/__pins.json; a release build ignores it entirely.

import Foundation
import RetroArchKit

enum QAEnvironment {

    static let envKey = "CARTOUCHE_QA_BASE_URL"
    // The file where the mock lists the sha256s it may legitimately serve
    static let pinsFile = "__pins.json"

    #if DEBUG
    static let isSupported = true

    // The QA server address, or nil in a normal run. Only http(s) with a host counts; anything else in the variable is ignored.
    static var base: URL? {
        base(from: env(envKey))
    }

    static var isActive: Bool { base != nil }

    // supported: is the release configuration, split out so tests can run the release code path in a debug build.
    static func base(from raw: String?, supported: Bool = isSupported) -> URL? {
        guard supported,
              let raw,
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host() != nil
        else { return nil }
        return url
    }

    // scheme, host, port and a base path prefix come from the base; path, query and fragment stay. Only http(s) re-points; everything else returns as given.
    static func url(_ url: URL) -> URL {
        Self.url(url, base: base)
    }

    static func url(_ url: URL, base: URL?) -> URL {
        guard let base,
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let swap = URLComponents(url: base, resolvingAgainstBaseURL: false)
        else { return url }
        parts.scheme = swap.scheme
        parts.host = swap.host
        parts.port = swap.port
        parts.user = nil
        parts.password = nil
        var prefix = swap.path
        while prefix.hasSuffix("/") { prefix.removeLast() }
        if !prefix.isEmpty { parts.path = prefix + parts.path }
        return parts.url ?? url
    }

    static func url(_ raw: String) -> URL? {
        URL(string: raw).map(url)
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config)
    }()

    // sha256s the QA server may serve, from <base>/__pins.json - synthetic fixtures cannot match real release pins.
    // Empty outside QA mode and when the server publishes none.
    static func extraHashes(session: URLSession = QAEnvironment.session) async -> Set<String> {
        guard let base else { return [] }
        guard let (data, response) = try? await session.data(from: base.appending(path: pinsFile)),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return [] }
        return hashes(in: data)
    }

    // Every lowercase sha256 in the JSON, whatever its shape: a bare list of hashes or a file name -> hash map both work
    static func hashes(in data: Data) -> Set<String> {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var found = Set<String>()
        collect(json, into: &found)
        return found
    }

    private static func collect(_ value: Any, into found: inout Set<String>) {
        switch value {
        case let text as String where isSHA256(text):
            found.insert(text)
        case let list as [Any]:
            for item in list { collect(item, into: &found) }
        case let map as [String: Any]:
            for (name, item) in map {
                collect(name, into: &found)
                collect(item, into: &found)
            }
        default:
            break
        }
    }

    private static func isSHA256(_ text: String) -> Bool {
        text.count == 64 && text.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    private static func env(_ key: String) -> String? {
        getenv(key).map { String(cString: $0) }
    }

    #else
    static let isSupported = false

    // A release build reads nothing and re-points nothing
    static var base: URL? { nil }
    static var isActive: Bool { false }
    static func base(from raw: String?, supported: Bool = isSupported) -> URL? { nil }
    static func url(_ url: URL) -> URL { url }
    static func url(_ url: URL, base: URL?) -> URL { url }
    static func url(_ raw: String) -> URL? { URL(string: raw) }
    static func extraHashes(session: URLSession) async -> Set<String> { [] }
    static func hashes(in data: Data) -> Set<String> { [] }
    #endif
}

// RetroArchKit is a separate package and cannot see QAEnvironment, so the app hands it these sources.

extension CoreSource {
    static var qa: CoreSource {
        CoreSource(cores: QAEnvironment.url(CoreSource.buildbot.cores),
                   info: QAEnvironment.url(CoreSource.buildbot.info))
    }
}

extension DatabaseSource {
    static var qa: DatabaseSource {
        DatabaseSource(base: QAEnvironment.url(DatabaseSource.libretro.base))
    }
}
