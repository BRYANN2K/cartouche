// QA mode for the harness in qa/. When CARTOUCHE_QA_BASE_URL names a server,
// every remote base address the app fetches is re-pointed there with its path
// kept, and downloads verified against a pinned hash also accept the sha256s
// the server lists in <base>/__pins.json. Without the variable nothing
// changes: url(_:) returns its argument and extraHashes is empty.
//
// QA mode exists in debug builds only (the qa-app Makefile target); a release
// build ignores the variable entirely — isSupported is false, the environment
// is never read, and url(_:)/extraHashes behave exactly as when it is unset.

import Foundation
import RetroArchKit

enum QAEnvironment {

    static let envKey = "CARTOUCHE_QA_BASE_URL"
    // The file where the mock lists the sha256s it may legitimately serve
    static let pinsFile = "__pins.json"

    #if DEBUG
    static let isSupported = true
    #else
    static let isSupported = false
    #endif

    // The QA server address, or nil in a normal run. Only http(s) with a host
    // counts; anything else in the variable is ignored.
    static var base: URL? {
        guard isSupported else { return nil }
        return base(from: env(envKey))
    }

    static var isActive: Bool { base != nil }

    // supported: is the release configuration, split out so tests can run the
    // release code path in a debug build.
    static func base(from raw: String?, supported: Bool = isSupported) -> URL? {
        guard supported,
              let raw,
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host() != nil
        else { return nil }
        return url
    }

    // The same address on the QA server: scheme, host and port (plus a base path
    // prefix when it has one) come from the base; path, query and fragment stay.
    // Only http and https are re-pointed — file, steam and other schemes are
    // returned as given, and so is everything without the variable.
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

    // The sha256s the QA server may legitimately serve, from <base>/__pins.json —
    // synthetic fixtures cannot match the pins real releases carry. Empty outside
    // QA mode and whenever the server does not publish the file.
    static func extraHashes(session: URLSession = QAEnvironment.session) async -> Set<String> {
        guard let base else { return [] }
        guard let (data, response) = try? await session.data(from: base.appending(path: pinsFile)),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return [] }
        return hashes(in: data)
    }

    // Every lowercase sha256 in the JSON, whatever its shape: a bare list of
    // hashes or a file name -> hash map both work
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
}

// RetroArchKit is a separate package and cannot see QAEnvironment, so the app
// hands it these sources in place of the shipped defaults.

extension CoreSource {
    // The libretro buildbot for cores and info.zip, re-pointed in QA mode
    static var qa: CoreSource {
        CoreSource(cores: QAEnvironment.url(CoreSource.buildbot.cores),
                   info: QAEnvironment.url(CoreSource.buildbot.info))
    }
}

extension DatabaseSource {
    // The libretro game database, re-pointed in QA mode
    static var qa: DatabaseSource {
        DatabaseSource(base: QAEnvironment.url(DatabaseSource.libretro.base))
    }
}
