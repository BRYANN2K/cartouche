import CryptoKit
import Foundation
import Testing

@testable import NotProtonApp

@Suite("Runner manifest")
struct RunnerManifestTests {

    static func entry(
        id: String = "wine-crossover-26.3.0-1", kind: String = "wineBuild",
        url: String = "https://github.com/BRYANN2K/cartouche/releases/download/wine-crossover-26.3.0-1/wine-crossover-26.3.0-1-x86_64.tar.xz",
        size: Int64 = 1234, sha256: String = String(repeating: "ab", count: 32),
        root: String = "wine-crossover-26.3.0-1", loader: String = "bin/wine", flavors: [String] = ["rosetta"]
    ) -> [String: Any] {
        [
            "id": id, "kind": kind, "origin": "cartouche", "name": "Wine CrossOver", "version": "26.3.0",
            "displayVersion": "26.3", "url": url, "size": size, "sha256": sha256, "root": root,
            "loader": loader, "flavors": flavors,
        ]
    }

    static func manifest(_ builds: [[String: Any]], revision: Int = 2, format: Int = 1) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["format": format, "revision": revision, "builds": builds])
    }

    @Test("The shipped manifest parses, and every build is pinned by size and SHA-256 on GitHub")
    func shipped() throws {
        let manifest = try RunnerManifest.bundled()
        #expect(manifest.format == 1)
        #expect(!manifest.builds.isEmpty)
        #expect(manifest.problems().isEmpty)
        let stable = try #require(manifest.build(id: "wine-stable-11.0_1"))
        #expect(stable.title == "Wine 11.0")
        #expect(stable.origin == .winehq)
        #expect(stable.sha256 == "b50dc50ec7f41d58b115a6b685d4d1315ba3c797bd3aa0f49213f2703cb82388")
        #expect(stable.size == 185_303_032)
        #expect(stable.archiveName == "wine-stable-11.0_1-osx64.tar.xz")
        #expect(stable.cpuFlavors == [.rosetta])
    }

    @Test("An entry CI wrote under the old Wine CrossOver name reads as Cartouche Wine, the build to download")
    func ciEntry() throws {
        let manifest = try RunnerManifest.read(Self.manifest([Self.entry()]))
        let build = try #require(manifest.builds.first)
        #expect(build.title == "Cartouche Wine 26.3")
        #expect(build.origin == .cartouche)
        #expect(build.root == "wine-crossover-26.3.0-1")
    }

    @Test("A hash that is not a full lowercase SHA-256 is refused", arguments: [
        "", "abc", String(repeating: "AB", count: 32), String(repeating: "zz", count: 32),
        String(repeating: "ab", count: 31),
    ])
    func wrongHash(_ hash: String) throws {
        #expect(throws: RunnerManifest.Invalid.self) {
            try RunnerManifest.read(Self.manifest([Self.entry(sha256: hash)]))
        }
    }

    @Test("Builds that could fetch from elsewhere, escape the runner folder or are not Wine are refused")
    func refusals() throws {
        let bad: [[String: Any]] = [
            Self.entry(url: "http://github.com/a/b/releases/download/t/x.tar.xz"),
            Self.entry(url: "https://example.com/x.tar.xz"),
            Self.entry(kind: "portingToolkit"),
            Self.entry(kind: "crossOver"),
            Self.entry(root: "../outside"),
            Self.entry(root: "/Applications"),
            Self.entry(loader: "bin/../../wine"),
            Self.entry(id: "../x"),
            Self.entry(id: "a b"),
            Self.entry(size: 0),
            Self.entry(flavors: ["arm64"]),
            Self.entry(flavors: []),
        ]
        for entry in bad {
            #expect(throws: RunnerManifest.Invalid.self, "\(entry)") {
                try RunnerManifest.read(Self.manifest([entry]))
            }
        }
        #expect(throws: RunnerManifest.Invalid.self) {
            try RunnerManifest.read(Self.manifest([Self.entry(), Self.entry()]))
        }
        #expect(throws: RunnerManifest.Invalid.self) {
            try RunnerManifest.read(Self.manifest([Self.entry()], format: 2))
        }
    }

    @Test("The bundled manifest lists Cartouche Wine with its release archive pinned")
    func shippedCrossOver() throws {
        let manifest = try RunnerManifest.bundled()
        let ours = try #require(manifest.build(id: "wine-crossover-26.3.0-1"))
        #expect(ours.origin == .cartouche)
        #expect(ours.name == "Cartouche Wine" && ours.displayVersion == "26.3")
        #expect(ours.root == "wine-crossover-26.3.0-1" && ours.loader == "bin/wine")
        #expect(ours.cpuFlavors == [.rosetta])
        #expect(ours.size == 149_444_708)
        #expect(ours.sha256 == "60400817826a053599193aa290d4e24e97213a743195f4187400bf9c74906887")
        #expect(ours.isPinned && !ours.isPending)
        #expect(RunnerOffer.recommended(manifest)?.id == ours.id)
    }

    @Test("A pending pin decodes and is listed, but install refuses it before any download")
    func pendingPin() async throws {
        let manifest = try RunnerManifest.read(Self.manifest([
            Self.entry(size: 0, sha256: RunnerManifest.pendingSHA256)]))
        let build = try #require(manifest.builds.first)
        #expect(build.isPending && !build.isPinned)
        #expect(RunnerOffer.recommended(manifest) == nil, "an unpinned build is never the onboarding offer")

        let work = try scratchDirectory("manifest-pending")
        defer { try? FileManager.default.removeItem(at: work) }
        await #expect(throws: StepFailure.self) {
            try await WineRunnerInstaller.install(
                build, runners: work.appending(path: "runners"),
                downloads: work.appending(path: "downloads"))
        }
        #expect((try? FileManager.default.contentsOfDirectory(atPath: work.appending(path: "downloads").path)) == nil,
                "the placeholder was refused before the downloads folder existed")
    }

    @Test("A pending pin with a size is malformed; other placeholder breaks are refused as before")
    func pendingMalformed() throws {
        #expect(throws: RunnerManifest.Invalid.self) {
            try RunnerManifest.read(Self.manifest([Self.entry(size: 1, sha256: RunnerManifest.pendingSHA256)]))
        }
        #expect(throws: RunnerManifest.Invalid.self) {
            try RunnerManifest.read(Self.manifest([Self.entry(url: "https://example.com/x.tar.xz",
                                                            size: 0, sha256: RunnerManifest.pendingSHA256)]))
        }
    }

    @Test("A refreshed manifest may fill a pending pin, never rewrite or revoke a shipped one")
    func pendingMerge() throws {
        let pending = try RunnerManifest.read(Self.manifest(
            [Self.entry(size: 0, sha256: RunnerManifest.pendingSHA256)], revision: 1))
        let pinned = try RunnerManifest.read(Self.manifest([Self.entry()], revision: 2))
        #expect(RunnerManifest.merged(bundled: pending, refreshed: pinned) == pinned)
        let reverted = try RunnerManifest.read(Self.manifest(
            [Self.entry(size: 0, sha256: RunnerManifest.pendingSHA256)], revision: 3))
        #expect(RunnerManifest.merged(bundled: pinned, refreshed: reverted) == pinned)
    }

    @Test("A newer refreshed manifest adds builds; an older one or one that changes a pin is ignored")
    func merge() throws {
        let shipped = try RunnerManifest.read(Self.manifest([Self.entry()], revision: 1))
        let added = try RunnerManifest.read(Self.manifest([Self.entry(), Self.entry(id: "wine-crossover-26.3.0-2")], revision: 2))
        #expect(RunnerManifest.merged(bundled: shipped, refreshed: added) == added)
        #expect(RunnerManifest.merged(bundled: added, refreshed: shipped) == added)
        #expect(RunnerManifest.merged(bundled: shipped, refreshed: nil) == shipped)
        let swapped = try RunnerManifest.read(Self.manifest(
            [Self.entry(sha256: String(repeating: "cd", count: 32))], revision: 3))
        #expect(RunnerManifest.merged(bundled: shipped, refreshed: swapped) == shipped)
    }

    static func feed(manifest: Data, key: Curve25519.Signing.PrivateKey) throws
        -> (Curve25519.Signing.PublicKey, @Sendable (URL) async throws -> (Data, Int)) {
        let signature = try key.signature(for: manifest)
        let sig = Data(signature.base64EncodedString().utf8)
        let fetch: @Sendable (URL) async throws -> (Data, Int) = { url in
            url.pathExtension == "sig" ? (sig, 200) : (manifest, 200)
        }
        return (key.publicKey, fetch)
    }

    @Test("Refresh keeps a valid signed newer copy, and refuses a broken one without touching the cache")
    func refresh() async throws {
        let work = try scratchDirectory("manifest")
        defer { try? FileManager.default.removeItem(at: work) }
        let cache = work.appending(path: "runners.json")
        let url = URL(string: "https://github.com/BRYANN2K/cartouche-wine/releases/download/manifest/runners.json")!
        let shipped = try RunnerManifest.bundled()
        // The refreshed copy must carry the shipped pin verbatim: rewriting it is refused.
        let pinned = try #require(shipped.build(id: "wine-crossover-26.3.0-1"))
        let newer = try Self.manifest(
            [Self.entry(url: pinned.url.absoluteString, size: pinned.size, sha256: pinned.sha256)],
            revision: shipped.revision + 1)
        let signing = Curve25519.Signing.PrivateKey()
        let (key, feed) = try Self.feed(manifest: newer, key: signing)

        let updated = await RunnerManifest.refresh(from: url, cache: cache, fetch: feed, key: key)
        #expect(updated == .updated(revision: shipped.revision + 1))
        #expect(RunnerManifest.current(cache: cache).build(id: "wine-crossover-26.3.0-1") != nil)
        #expect(
            FileManager.default.fileExists(
                atPath: RunnerManifest.signatureFile(for: cache).path(percentEncoded: false)),
            "the signature the refresh fetched is kept beside the cache")

        let broken = try Self.manifest([Self.entry(sha256: "nope")], revision: shipped.revision + 5)
        let brokenFeed = try Self.feed(manifest: broken, key: signing)
        let rejected = await RunnerManifest.refresh(from: url, cache: cache, fetch: brokenFeed.1, key: key)
        guard case .rejected = rejected else { Issue.record("\(rejected)"); return }
        #expect(try Data(contentsOf: cache) == newer)

        let same = await RunnerManifest.refresh(from: url, cache: cache, fetch: feed, key: key)
        #expect(same == .unchanged)
        let missing = await RunnerManifest.refresh(from: url, cache: cache, fetch: { _ in (Data(), 404) }, key: key)
        #expect(missing == .unavailable)
    }

    @Test("A signed manifest from cartouche-wine adding the next revision offers it as an update")
    func remoteRevisionOffersUpdate() async throws {
        let work = try scratchDirectory("manifest-update")
        defer { try? FileManager.default.removeItem(at: work) }
        let cache = work.appending(path: "runners.json")
        let url = try #require(RunnerManifest.feed(
            fromInfoValue: "https://github.com/BRYANN2K/cartouche-wine/releases/download/manifest/runners.json"))
        let shipped = try RunnerManifest.bundled()
        let pinned = try #require(shipped.build(id: "wine-crossover-26.3.0-1"))
        let next = "wine-crossover-26.3.0-2"
        let newer = try Self.manifest([
            Self.entry(url: pinned.url.absoluteString, size: pinned.size, sha256: pinned.sha256),
            Self.entry(id: next,
                       url: "https://github.com/BRYANN2K/cartouche-wine/releases/download/\(next)/\(next)-x86_64.tar.xz",
                       root: next),
        ], revision: shipped.revision + 1)
        let signing = Curve25519.Signing.PrivateKey()
        let (key, feed) = try Self.feed(manifest: newer, key: signing)
        let asked = LockedURLs()

        let outcome = await RunnerManifest.refresh(from: url, cache: cache, fetch: { asked.add($0); return try await feed($0) }, key: key)
        #expect(outcome == .updated(revision: shipped.revision + 1))
        #expect(asked.all == [url, RunnerManifest.signatureFile(for: url)])

        let merged = RunnerManifest.current(cache: cache, key: key)
        let installed: Set<String> = ["wine-crossover-26.3.0-1"]
        #expect(RunnerUpdate.offers(installed: installed, manifest: merged)["wine-crossover-26.3.0-1"]?.id == next)
        // Without the remote copy only the bundled builds are known
        #expect(RunnerUpdate.offers(installed: installed, manifest: shipped)["wine-crossover-26.3.0-1"]?.id != next)
    }

    final class LockedURLs: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [URL] = []
        func add(_ url: URL) { lock.withLock { list.append(url) } }
        var all: [URL] { lock.withLock { list } }
    }

    @Test("A manifest with a missing or wrong signature is refused and the bundled copy stays")
    func unsignedOrForged() async throws {
        let work = try scratchDirectory("manifest-unsigned")
        defer { try? FileManager.default.removeItem(at: work) }
        let cache = work.appending(path: "runners.json")
        let url = URL(string: "https://github.com/BRYANN2K/cartouche-wine/releases/download/manifest/runners.json")!
        let shipped = try RunnerManifest.bundled()
        let newer = try Self.manifest([Self.entry()], revision: shipped.revision + 1)
        let key = Curve25519.Signing.PrivateKey().publicKey

        let noSig = await RunnerManifest.refresh(from: url, cache: cache, fetch: { url in
            url.pathExtension == "sig" ? (Data(), 404) : (newer, 200)
        }, key: key)
        guard case .rejected = noSig else { Issue.record("\(noSig)"); return }
        #expect(!FileManager.default.fileExists(atPath: cache.path(percentEncoded: false)))

        let forged = try Self.feed(manifest: newer, key: Curve25519.Signing.PrivateKey())
        let wrong = await RunnerManifest.refresh(from: url, cache: cache, fetch: forged.1, key: key)
        guard case .rejected = wrong else { Issue.record("\(wrong)"); return }
        #expect(!FileManager.default.fileExists(atPath: cache.path(percentEncoded: false)))

        let garbage = await RunnerManifest.refresh(from: url, cache: cache, fetch: { url in
            url.pathExtension == "sig" ? (Data("not a signature".utf8), 200) : (newer, 200)
        }, key: key)
        guard case .rejected = garbage else { Issue.record("\(garbage)"); return }

        // The bundled manifest is what the app installs from
        #expect(RunnerManifest.current(cache: cache) == shipped)
    }

    @Test("A signed cache is read; an unsigned or forged one is ignored")
    func cachedSignature() async throws {
        let work = try scratchDirectory("manifest-cache")
        defer { try? FileManager.default.removeItem(at: work) }
        let cache = work.appending(path: "runners.json")
        let shipped = try RunnerManifest.bundled()
        // The refreshed copy must carry the shipped pin verbatim: rewriting it is refused.
        let pinned = try #require(shipped.build(id: "wine-crossover-26.3.0-1"))
        let newer = try Self.manifest(
            [Self.entry(url: pinned.url.absoluteString, size: pinned.size, sha256: pinned.sha256)],
            revision: shipped.revision + 1)

        // A cache written before signatures were kept is not trusted
        try newer.write(to: cache)
        let key = Curve25519.Signing.PrivateKey().publicKey
        #expect(RunnerManifest.current(cache: cache, key: key) == shipped)

        let signing = Curve25519.Signing.PrivateKey()
        let signature = try signing.signature(for: newer)
        try Data(signature.base64EncodedString().utf8)
            .write(to: RunnerManifest.signatureFile(for: cache))
        #expect(RunnerManifest.current(cache: cache, key: key) == shipped)
        let accepted = RunnerManifest.current(cache: cache, key: signing.publicKey)
        #expect(accepted.revision == shipped.revision + 1)
        #expect(accepted.build(id: "wine-crossover-26.3.0-1") != nil)
    }

    @Test("The signature file sits beside the manifest and parses base64 or sign_update output")
    func signatureFile() throws {
        let url = URL(string: "https://github.com/BRYANN2K/cartouche-wine/releases/download/manifest/runners.json")!
        #expect(RunnerManifest.signatureFile(for: url).absoluteString == url.absoluteString + ".sig")

        let signature = try Curve25519.Signing.PrivateKey().signature(for: Data("manifest".utf8))
        #expect(RunnerManifest.signature(from: Data(signature.base64EncodedString().utf8)) == signature)
        let sparkle = Data("sparkle:edSignature=\"\(signature.base64EncodedString())\" length=\"8\"\n".utf8)
        #expect(RunnerManifest.signature(from: sparkle) == signature)
        #expect(RunnerManifest.signature(from: Data("%%%".utf8)) == nil)
    }

    @Test("The refreshed copy comes from the manifest release of the public cartouche-wine repository")
    func feed() throws {
        let plist = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: CompatFixture.repo.appending(path: "app/Info.plist")), format: nil)
        let value = (plist as? [String: Any])?[RunnerManifest.feedKey]
        let feed = try #require(RunnerManifest.feed(fromInfoValue: value))
        #expect(feed.absoluteString
            == "https://github.com/BRYANN2K/cartouche-wine/releases/download/manifest/runners.json")
        #expect(RunnerManifest.signatureFile(for: feed).absoluteString
            == "https://github.com/BRYANN2K/cartouche-wine/releases/download/manifest/runners.json.sig")

        // Only https on an allowed host, and only a runners.json, is ever fetched
        for refused: Any? in [
            nil, 42, "",
            "http://github.com/BRYANN2K/cartouche-wine/releases/download/manifest/runners.json",
            "https://objects.githubusercontent.com/manifest/runners.json",
            "https://example.org/BRYANN2K/cartouche-wine/releases/download/manifest/runners.json",
            "https://github.com/BRYANN2K/cartouche-wine/releases/download/manifest/compat.json.gz",
        ] {
            #expect(RunnerManifest.feed(fromInfoValue: refused) == nil, "\(String(describing: refused))")
        }
    }
}
