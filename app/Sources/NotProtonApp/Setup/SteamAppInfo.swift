// macOS builds from Steam's binary appinfo.vdf cache (common/oslist); the parser is AppInfoVDF.

import Foundation

enum SteamAppInfo {

    static var cache: URL { SupportPaths.Steam.userData.appending(path: "appcache/appinfo.vdf") }

    struct Platforms: Equatable, Sendable {
        var mac: Set<Int> = []
        var windows: Set<Int> = []
        var sizes: [Int: Storage] = [:]

        var both: Set<Int> { mac.intersection(windows) }
    }

    typealias Failure = AppInfoVDF.ParseError

    private static let fileCache = FileCache()

    static func platforms(at url: URL = cache) -> Platforms? {
        fileCache.platforms(at: url)
    }

    // Callers keep this synchronous file read and parse off the main actor.
    final class FileCache: @unchecked Sendable {
        private struct Stamp: Equatable {
            let url: URL
            let modified: Date
            let size: UInt64
        }

        private let lock = NSLock()
        private let read: (URL) throws -> Data
        private var stamp: Stamp?
        private var value: Platforms?

        init(read: @escaping (URL) throws -> Data = { try Data(contentsOf: $0) }) {
            self.read = read
        }

        func platforms(at url: URL) -> Platforms? {
            lock.lock()
            defer { lock.unlock() }
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false)),
                  let modified = attributes[.modificationDate] as? Date,
                  let size = attributes[.size] as? NSNumber else { return nil }
            let current = Stamp(url: url, modified: modified, size: size.uint64Value)
            if stamp == current { return value }
            value = (try? read(url)).flatMap { try? SteamAppInfo.platforms(Array($0)) }
            stamp = current
            return value
        }
    }

    struct Storage: Equatable, Sendable {
        var windows: Int64 = 0
        var mac: Int64 = 0
    }

    // Public base-game depots only: optional DLC and other languages are not part of this estimate.
    static func storage(_ app: [String: AppInfoVDF.Value]) -> Storage {
        guard case .section(let depots)? = app["depots"] else { return Storage() }
        func text(_ value: AppInfoVDF.Value?) -> String? {
            if case .string(let text)? = value { return text }
            return nil
        }
        func bytes(_ value: AppInfoVDF.Value?) -> Int64? {
            switch value {
            case .number(let n)?: return n >= 0 ? n : nil
            case .string(let s)?: return Int64(s).flatMap { $0 >= 0 ? $0 : nil }
            default: return nil
            }
        }
        var result = Storage()
        for (id, node) in depots where UInt32(id) != nil {
            guard case .section(let depot) = node, depot["dlcappid"] == nil,
                  case .section(let manifests)? = depot["manifests"],
                  case .section(let manifest)? = manifests["public"], let size = bytes(manifest["size"])
            else { continue }
            let config: [String: AppInfoVDF.Value]
            if case .section(let c)? = depot["config"] { config = c } else { config = [:] }
            if let language = text(config["language"]), language != "english" { continue }
            let systems = text(config["oslist"])?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if systems == nil || systems!.contains("windows") {
                let (total, overflow) = result.windows.addingReportingOverflow(size)
                if !overflow { result.windows = total }
            }
            if systems == nil || systems!.contains("macos") {
                let (total, overflow) = result.mac.addingReportingOverflow(size)
                if !overflow { result.mac = total }
            }
        }
        return result
    }

    // Steam treats an app without an oslist as Windows only
    static func platforms(_ b: [UInt8]) throws -> Platforms {
        var out = Platforms()
        let complete = try AppInfoVDF.forEachApp(b) { id, keys in
            let app = try keys()
            out.sizes[Int(id)] = storage(app)
            guard case .section(let common)? = app["common"] else { return true }
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
