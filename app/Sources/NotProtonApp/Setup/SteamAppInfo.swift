// macOS builds from Steam's binary appinfo.vdf cache (common/oslist); the parser is AppInfoVDF.

import Foundation

enum SteamAppInfo {

    static var cache: URL { SupportPaths.Steam.userData.appending(path: "appcache/appinfo.vdf") }

    struct Platforms: Equatable, Sendable {
        var mac: Set<Int> = []
        var windows: Set<Int> = []

        var both: Set<Int> { mac.intersection(windows) }
    }

    typealias Failure = AppInfoVDF.ParseError

    static func platforms(at url: URL = cache) -> Platforms? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? platforms(Array(data))
    }

    // Steam treats an app without an oslist as Windows only
    static func platforms(_ b: [UInt8]) throws -> Platforms {
        var out = Platforms()
        let complete = try AppInfoVDF.forEachApp(b) { id, keys in
            guard case .section(let common)? = try keys()["common"] else { return true }
            guard case .string(let oslist)? = common["oslist"] else {
                out.windows.insert(Int(id))
                return true
            }
            let systems = oslist.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if systems.contains("macos") { out.mac.insert(Int(id)) }
            if systems.contains("windows") { out.windows.insert(Int(id)) }
            return true
        }
        guard complete else { throw Failure.truncated }
        return out
    }
}
