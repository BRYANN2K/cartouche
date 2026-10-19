// The Wine builds Cartouche may download, each pinned by URL, size and SHA-256.
// Shipped with the app as runners.json; a newer copy published next to the
// compatibility data can add builds without an app update.

import Foundation

struct RunnerManifest: Sendable, Equatable, Codable {

    static let format = 1

    struct Build: Sendable, Equatable, Codable, Identifiable {
        enum Origin: String, Sendable, Codable {
            // Built by Cartouche's CI from CodeWeavers' sources
            case cartouche
            // WineHQ's official macOS builds, made by Gcenx
            case winehq
        }

        let id: String
        let kind: String
        let origin: Origin
        // Product name, not translated
        let name: String
        let version: String
        let displayVersion: String
        let url: URL
        let size: Int64
        let sha256: String
        // The folder inside the archive that becomes runners/wine-<id>
        let root: String
        let loader: String
        let flavors: [String]

        var title: String { "\(name) \(displayVersion)" }

        var archiveName: String { url.lastPathComponent }

        var cpuFlavors: [CompatTool.Flavor] { flavors.compactMap(CompatTool.Flavor.init(rawValue:)) }
    }

    let format: Int
    // Grows with every published change, so an older copy never replaces a newer one
    let revision: Int
    let builds: [Build]

    func build(id: String) -> Build? { builds.first { $0.id == id } }

    struct Invalid: Error, Equatable, CustomStringConvertible {
        let problems: [String]
        var description: String { problems.joined(separator: "; ") }
    }

    // Downloads come only from release assets on GitHub
    static let allowedHosts: Set<String> = ["github.com"]

    static func read(_ data: Data) throws -> RunnerManifest {
        let manifest = try JSONDecoder().decode(RunnerManifest.self, from: data)
        let problems = manifest.problems()
        guard problems.isEmpty else { throw Invalid(problems: problems) }
        return manifest
    }

    func problems() -> [String] {
        var found: [String] = []
        if format != Self.format { found.append("format \(format) is not \(Self.format)") }
        var ids: Set<String> = []
        for build in builds {
            let at = "build \(build.id)"
            if !ids.insert(build.id).inserted { found.append("\(at) is listed twice") }
            if build.id.isEmpty || build.id.contains(where: { !($0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0))) })
                || build.id.hasPrefix(".") {
                found.append("\(at): the id can only hold letters, digits, dot, dash and underscore")
            }
            // Game Porting Toolkit and CrossOver come from the user's Mac, never from a download
            if build.kind != Runner.Kind.wineBuild.rawValue { found.append("\(at): kind \(build.kind) is not downloadable") }
            if build.url.scheme != "https" || !Self.allowedHosts.contains(build.url.host() ?? "") {
                found.append("\(at): \(build.url.absoluteString) is not an https URL on \(Self.allowedHosts.sorted().joined(separator: ", "))")
            }
            if build.size <= 0 { found.append("\(at): size \(build.size)") }
            if !Self.isSHA256(build.sha256) { found.append("\(at): \(build.sha256) is not a SHA-256") }
            for (label, path) in [("root", build.root), ("loader", build.loader)] where !Self.isInside(path) {
                found.append("\(at): \(label) \(path) leaves the runner folder")
            }
            if build.cpuFlavors.count != build.flavors.count || build.flavors.isEmpty {
                found.append("\(at): flavors \(build.flavors)")
            }
        }
        return found
    }

    static func isSHA256(_ text: String) -> Bool {
        text.count == 64 && text.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    // A relative path with no step out of its folder
    static func isInside(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.split(separator: "/").contains("..")
    }
}

extension RunnerManifest {

    static func bundled() throws -> RunnerManifest {
        guard let url = Bundle.module.url(forResource: "runners", withExtension: "json") else {
            throw Invalid(problems: ["runners.json is not in the app"])
        }
        return try read(Data(contentsOf: url))
    }

    static var cacheFile: URL { SupportPaths.support.appending(path: "runners.json") }

    // The newer of the shipped copy and a refreshed one. A refreshed copy may add builds
    // and drop them, but a build it shares with the shipped copy must keep its pin.
    static func merged(bundled: RunnerManifest, refreshed: RunnerManifest?) -> RunnerManifest {
        guard let refreshed, refreshed.revision > bundled.revision else { return bundled }
        for build in refreshed.builds {
            if let shipped = bundled.build(id: build.id), shipped != build {
                AppLog.note("runner manifest revision \(refreshed.revision) changes the pin of \(build.id), ignored")
                return bundled
            }
        }
        return refreshed
    }

    // What the app installs from. Falls back to an empty list only if the app itself is broken.
    static func current(cache: URL = cacheFile) -> RunnerManifest {
        let shipped: RunnerManifest
        do {
            shipped = try bundled()
        } catch {
            AppLog.note("runners.json in the app is unreadable: \(error)")
            shipped = RunnerManifest(format: format, revision: 0, builds: [])
        }
        let refreshed = (try? Data(contentsOf: cache)).flatMap { try? read($0) }
        return merged(bundled: shipped, refreshed: refreshed)
    }

    // .../releases/download/compat-data/compat.json.gz -> .../compat-data/runners.json
    static func feed(fromCompatibilityFeed feed: URL) -> URL {
        feed.deletingLastPathComponent().appending(path: "runners.json")
    }

    enum RefreshOutcome: Sendable, Equatable {
        case updated(revision: Int)
        case unchanged
        case rejected(String)
        case unavailable
    }

    // Keeps the published copy when it is valid and newer than what the app has
    static func refresh(
        from url: URL, cache: URL = cacheFile,
        fetch: @Sendable (URL) async throws -> (Data, Int) = CompatibilityClient.download
    ) async -> RefreshOutcome {
        guard let (data, status) = try? await fetch(url), status == 200 else { return .unavailable }
        let published: RunnerManifest
        do {
            published = try read(data)
        } catch {
            AppLog.note("runner manifest at \(url.absoluteString) refused: \(error)")
            return .rejected(String(describing: error))
        }
        let have = current(cache: cache)
        guard published.revision > have.revision else { return .unchanged }
        guard merged(bundled: have, refreshed: published) == published else {
            return .rejected("revision \(published.revision) changes a pinned build")
        }
        do {
            try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
            try atomicReplace(cache, with: data, step: "runner manifest")
        } catch {
            AppLog.note("runner manifest not saved: \(error)")
            return .unavailable
        }
        return .updated(revision: published.revision)
    }
}
