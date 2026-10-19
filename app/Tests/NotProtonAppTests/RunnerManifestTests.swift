import Foundation
import Testing

@testable import NotProtonApp

@Suite("Runner manifest")
struct RunnerManifestTests {

    static func entry(
        id: String = "wine-crossover-26.3.0-1", kind: String = "wineBuild",
        url: String = "https://github.com/BRYANN2K/NotProton/releases/download/wine-crossover-26.3.0-1/wine-crossover-26.3.0-1-x86_64.tar.xz",
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

    @Test("An entry CI writes for Wine CrossOver reads as the build to download")
    func ciEntry() throws {
        let manifest = try RunnerManifest.read(Self.manifest([Self.entry()]))
        let build = try #require(manifest.builds.first)
        #expect(build.title == "Wine CrossOver 26.3")
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

    @Test("Refresh keeps a valid newer copy, and refuses a broken one without touching the cache")
    func refresh() async throws {
        let work = try scratchDirectory("manifest")
        defer { try? FileManager.default.removeItem(at: work) }
        let cache = work.appending(path: "runners.json")
        let url = URL(string: "https://github.com/BRYANN2K/NotProton/releases/download/compat-data/runners.json")!
        let shipped = try RunnerManifest.bundled()
        let newer = try Self.manifest([Self.entry()], revision: shipped.revision + 1)

        let updated = await RunnerManifest.refresh(from: url, cache: cache) { _ in (newer, 200) }
        #expect(updated == .updated(revision: shipped.revision + 1))
        #expect(RunnerManifest.current(cache: cache).build(id: "wine-crossover-26.3.0-1") != nil)

        let broken = try Self.manifest([Self.entry(sha256: "nope")], revision: shipped.revision + 5)
        let rejected = await RunnerManifest.refresh(from: url, cache: cache) { _ in (broken, 200) }
        guard case .rejected = rejected else { Issue.record("\(rejected)"); return }
        #expect(try Data(contentsOf: cache) == newer)

        let same = await RunnerManifest.refresh(from: url, cache: cache) { _ in (newer, 200) }
        #expect(same == .unchanged)
        let missing = await RunnerManifest.refresh(from: url, cache: cache) { _ in (Data(), 404) }
        #expect(missing == .unavailable)
    }

    @Test("The refreshed copy sits next to the compatibility file")
    func feed() {
        let compat = URL(string: "https://github.com/BRYANN2K/NotProton/releases/download/compat-data/compat.json.gz")!
        #expect(RunnerManifest.feed(fromCompatibilityFeed: compat).absoluteString
            == "https://github.com/BRYANN2K/NotProton/releases/download/compat-data/runners.json")
    }
}
