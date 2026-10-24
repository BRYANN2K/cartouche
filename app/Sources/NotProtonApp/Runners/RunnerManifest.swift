// Each build pinned by URL, size and SHA-256; a published manifest is trusted only with a valid EdDSA signature from the Sparkle key.

import CryptoKit
import Foundation

struct RunnerManifest: PinnedManifest {

    typealias Invalid = ManifestInvalid
    static let format = 1
    static let resource = "runners"
    // A build CI has listed before its archive exists: shown in Runners, but nothing installs from
    // it — no file hashes to the placeholder, and the installer refuses it before any download.
    static let pendingSHA256 = "TODO-FILL-AFTER-RELEASE"

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

        // A real pin: size and SHA-256 an archive can match. A pending placeholder fails every
        // check it goes through, so it can never install.
        var isPinned: Bool { size > 0 && RunnerManifest.isSHA256(sha256) }

        var isPending: Bool { sha256 == RunnerManifest.pendingSHA256 }

        var cpuFlavors: [CompatTool.Flavor] { flavors.compactMap(CompatTool.Flavor.init(rawValue:)) }

        // Our build's name; manifests published before the rename still say "Wine CrossOver"
        static let cartoucheName = "Cartouche Wine"
        static let legacyCartoucheName = "Wine CrossOver"
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
            if build.isPending {
                if build.size != 0 { found.append("\(at): a pending pin keeps size 0") }
            } else {
                if build.size <= 0 { found.append("\(at): size \(build.size)") }
                if !Self.isSHA256(build.sha256) { found.append("\(at): \(build.sha256) is not a SHA-256") }
            }
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

extension RunnerManifest.Build {

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decode(String.self, forKey: .kind)
        origin = try c.decode(Origin.self, forKey: .origin)
        let named = try c.decode(String.self, forKey: .name)
        name = origin == .cartouche && named == Self.legacyCartoucheName ? Self.cartoucheName : named
        version = try c.decode(String.self, forKey: .version)
        displayVersion = try c.decode(String.self, forKey: .displayVersion)
        url = try c.decode(URL.self, forKey: .url)
        size = try c.decode(Int64.self, forKey: .size)
        sha256 = try c.decode(String.self, forKey: .sha256)
        root = try c.decode(String.self, forKey: .root)
        loader = try c.decode(String.self, forKey: .loader)
        flavors = try c.decode([String].self, forKey: .flavors)
    }
}

extension RunnerManifest {

    static var cacheFile: URL { SupportPaths.support.appending(path: "runners.json") }

    // A refreshed copy may add or drop builds, but a shared build must keep its pin.
    static func merged(bundled: RunnerManifest, refreshed: RunnerManifest?) -> RunnerManifest {
        guard let refreshed, refreshed.revision > bundled.revision else { return bundled }
        for build in refreshed.builds {
            // A pending placeholder pins nothing yet, so the refreshed copy may fill it.
            if let shipped = bundled.build(id: build.id), shipped != build, shipped.isPinned {
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

    static let feedKey = "CartoucheRunnerManifestURL"

    // The manifest release of the public cartouche-wine repository, named once in Info.plist.
    // GitHub answers with a redirect to its download host; URLSession follows it, and the
    // signature, not the host that served the bytes, decides whether the copy is trusted.
    static var feed: URL? {
        feed(fromInfoValue: Bundle.main.object(forInfoDictionaryKey: feedKey)).map(QAEnvironment.url)
    }

    // Only an https address on an allowed host counts, like the builds it lists
    static func feed(fromInfoValue value: Any?) -> URL? {
        guard let raw = value as? String, let url = URL(string: raw),
              url.scheme == "https", allowedHosts.contains(url.host() ?? ""), url.lastPathComponent == "runners.json"
        else { return nil }
        return url
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
