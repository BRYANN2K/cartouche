// Each build pinned by URL, size and SHA-256; a published manifest is trusted only with a valid EdDSA signature from the Sparkle key.

import CryptoKit
import Foundation

struct RunnerManifest: PinnedManifest {

    typealias Invalid = ManifestInvalid
    static let format = 1
    static let resource = "runners"

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
        let name: String
        let version: String
        let displayVersion: String
        let url: URL
        let size: Int64
        let sha256: String
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

    // Downloads come only from release assets on GitHub
    static let allowedHosts: Set<String> = ["github.com"]

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
}

extension RunnerManifest {

    static var cacheFile: URL { SupportPaths.support.appending(path: "runners.json") }

    // A refreshed copy may add or drop builds, but a shared build must keep its pin.
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

    static func current(cache: URL = cacheFile, key: Curve25519.Signing.PublicKey? = signingKey()) -> RunnerManifest {
        let shipped: RunnerManifest
        do {
            shipped = try bundled()
        } catch {
            AppLog.note("runners.json in the app is unreadable: \(error)")
            shipped = RunnerManifest(format: format, revision: 0, builds: [])
        }
        let refreshed = verified(cache: cache, key: key).flatMap { try? read($0) }
        return merged(bundled: shipped, refreshed: refreshed)
    }

    // Without a signed .sig a cached copy could offer builds CI never pinned; a missing key means an unsigned build environment, so the cache is read as is.
    private static func verified(cache: URL, key: Curve25519.Signing.PublicKey?) -> Data? {
        guard let data = try? Data(contentsOf: cache) else { return nil }
        guard let key else { return data }
        guard let signatureData = try? Data(contentsOf: signatureFile(for: cache)),
              let signature = signature(from: signatureData),
              key.isValidSignature(signature, for: data)
        else {
            AppLog.note("cached runner manifest refused: missing or wrong signature")
            return nil
        }
        return data
    }

    // .../releases/download/compat-data/compat.json.gz -> .../compat-data/runners.json
    static func feed(fromCompatibilityFeed feed: URL) -> URL {
        feed.deletingLastPathComponent().appending(path: "runners.json")
    }

    // runners.json -> runners.json.sig, the detached signature CI publishes beside it
    static func signatureFile(for manifest: URL) -> URL {
        manifest.appendingPathExtension("sig")
    }

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
        case rejected
        case unavailable
    }

    // Unsigned or invalid manifests are refused; the bundled copy stays.
    static func refresh(
        from url: URL, cache: URL = cacheFile,
        fetch: @Sendable (URL) async throws -> (Data, Int) = HTTPFetch.download(
            timeout: 30, resourceTimeout: 5 * 60, userAgent: "Cartouche/\(AppVersion.bundled)"),
        key: Curve25519.Signing.PublicKey? = signingKey()
    ) async -> RefreshOutcome {
        guard let (data, status) = try? await fetch(url), status == 200 else { return .unavailable }
        // A signature that cannot be fetched at all is retried at the next check
        guard let signed = try? await fetch(signatureFile(for: url)) else { return .unavailable }
        guard signed.1 == 200, let signature = signature(from: signed.0), let key,
              key.isValidSignature(signature, for: data)
        else {
            AppLog.note("runner manifest at \(url.absoluteString) refused: missing or wrong signature")
            return .rejected
        }
        let published: RunnerManifest
        do {
            published = try read(data)
        } catch {
            AppLog.note("runner manifest at \(url.absoluteString) refused: \(error)")
            return .rejected
        }
        let have = current(cache: cache, key: key)
        guard published.revision > have.revision else { return .unchanged }
        guard merged(bundled: have, refreshed: published) == published else {
            return .rejected
        }
        do {
            try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
            try atomicReplace(cache, with: data, step: "runner manifest")
            try atomicReplace(signatureFile(for: cache), with: signed.0, step: "runner manifest signature")
        } catch {
            AppLog.note("runner manifest not saved: \(error)")
            return .unavailable
        }
        return .updated(revision: published.revision)
    }
}
