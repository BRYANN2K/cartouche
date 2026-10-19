// The Wine builds Cartouche may download, each pinned by URL, size and SHA-256.
// Shipped with the app as runners.json; a newer copy published next to the
// compatibility data can add builds without an app update. The published copy is
// trusted only with a valid EdDSA signature from the Sparkle key (docs/RELEASE.md).

import CryptoKit
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

    // runners.json -> runners.json.sig, the detached signature CI publishes beside it
    static func signatureFile(for manifest: URL) -> URL {
        manifest.appendingPathExtension("sig")
    }

    // The public half of the key CI signs with: the Sparkle key, already shipped for
    // the appcast as SUPublicEDKey. Nil outside the app bundle (tests pass their own).
    static func signingKey(bundle: Bundle = .main) -> Curve25519.Signing.PublicKey? {
        (bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String)
            .flatMap { Data(base64Encoded: $0) }
            .flatMap { try? Curve25519.Signing.PublicKey(rawRepresentation: $0) }
    }

    // A .sig holds the base64 signature; sign_update's own "edSignature" text parses too
    static func signature(from data: Data) -> Data? {
        var text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if let quoted = text.firstMatch(of: /edSignature="([^"]+)"/) { text = String(quoted.1) }
        return Data(base64Encoded: text)
    }

    enum RefreshOutcome: Sendable, Equatable {
        case updated(revision: Int)
        case unchanged
        case rejected(String)
        case unavailable
    }

    // Keeps the published copy when it is signed, valid and newer than what the app has.
    // A manifest the shipped key does not sign is refused and the bundled copy stays.
    static func refresh(
        from url: URL, cache: URL = cacheFile,
        fetch: @Sendable (URL) async throws -> (Data, Int) = CompatibilityClient.download,
        key: Curve25519.Signing.PublicKey? = signingKey()
    ) async -> RefreshOutcome {
        guard let (data, status) = try? await fetch(url), status == 200 else { return .unavailable }
        // A signature that cannot be fetched at all is retried at the next check
        guard let signed = try? await fetch(signatureFile(for: url)) else { return .unavailable }
        guard signed.1 == 200, let signature = signature(from: signed.0), let key,
              key.isValidSignature(signature, for: data)
        else {
            AppLog.note("runner manifest at \(url.absoluteString) refused: missing or wrong signature")
            return .rejected("missing or wrong signature")
        }
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
