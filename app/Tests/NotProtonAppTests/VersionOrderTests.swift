import Foundation
import Testing

@testable import NotProtonApp

@Suite("Version order")
struct VersionOrderTests {

    // Shared with packaging/tests/test_release.py, so the app and the release tools agree
    static func ordered() throws -> [String] {
        let text = try String(contentsOf: IdentityTests.repoRoot.appending(path: "packaging/tests/version-order.txt"),
                              encoding: .utf8)
        return text.split(separator: "\n").map(String.init)
    }

    @Test("Pre-releases come before their release, betas and tests in number order")
    func preReleasesOrder() {
        let cases: [(String, String)] = [
            ("0.1.0", "0.2.0-beta.1"), ("0.2.0-beta.1", "0.2.0-beta.2"), ("0.2.0-beta.2", "0.2.0"),
            ("0.0.1-test.1", "0.0.1-test.2"), ("0.2.0-beta.9", "0.2.0-beta.10"), ("0.9.0", "0.10.0"),
        ]
        for (older, newer) in cases {
            #expect(CartoucheVersion.compare(older, newer) == .orderedAscending, "\(older) < \(newer)")
            #expect(CartoucheVersion.compare(newer, older) == .orderedDescending, "\(newer) > \(older)")
        }
        #expect(CartoucheVersion.compare("0.2.0", "0.2.0") == .orderedSame)
        #expect(CartoucheVersion.compare("0.2.0", "0.2") == .orderedSame)
        #expect(CartoucheVersion.compare("0.2.0+abc", "0.2.0") == .orderedSame)
    }

    @Test("The shared list sorts the same way as the release tools")
    func sharedOrder() throws {
        let ordered = try Self.ordered()
        #expect(ordered.count > 5)
        for (older, newer) in zip(ordered, ordered.dropFirst()) {
            #expect(CartoucheVersion.compare(older, newer) == .orderedAscending, "\(older) < \(newer)")
        }
        let sorted = ordered.reversed().sorted { CartoucheVersion.compare($0, $1) == .orderedAscending }
        #expect(sorted == ordered)
    }

    @Test("A string that is not a version falls back to numeric order")
    func fallback() {
        #expect(CartoucheVersion.compare("build 9", "build 10") == .orderedAscending)
        #expect(CartoucheVersion.compare("0.2.0-", "0.2.0") != .orderedSame)
    }

    @Test("Moving from a beta to its release is an update, not a newer installation")
    func betaToRelease() throws {
        let root = try scratchDirectory("content")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "source")
        let destination = root.appending(path: "installed")
        try Data("new!".utf8).write(to: source)
        try Data("old!".utf8).write(to: destination)
        let files = [DeploymentContent.File(source: source, destination: destination, name: "run")]
        let release = DeploymentContent.Build(version: "0.2.0", builtAt: 100)
        let beta = DeploymentContent.Build(version: "0.2.0-beta.2", builtAt: 200)

        #expect(try DeploymentContent.inspect(files: files, bundled: release, installed: beta) == .update(["run"]))
        #expect(try DeploymentContent.inspect(files: files, bundled: beta, installed: release) == .newerInstalled)
        #expect(try DeploymentContent.inspect(files: files, bundled: release, installed: nil,
                                              legacyVersion: "0.2.0-beta.1") == .update(["run"]))
        #expect(try DeploymentContent.inspect(files: files, bundled: beta, installed: nil,
                                              legacyVersion: "0.2.0") == .newerInstalled)
    }

    // NotProton keeps its own dylib.version (1.2.0 on a machine running it). Cartouche
    // reads only the record in its own folder, so 0.1.0 is never refused because of it.
    @Test("NotProton's deployed version is never compared with Cartouche's")
    func notProtonRecordIsIgnored() throws {
        let support = SupportPaths.deployedVersion.deletingLastPathComponent()
        #expect(support.lastPathComponent == "Cartouche")
        #expect(!SupportPaths.deployedVersion.path.lowercased().contains("notproton"))
        #expect(DeploymentContent.record(beside: SupportPaths.deployedVersion).deletingLastPathComponent() == support)

        let home = try scratchDirectory("coexist")
        defer { try? FileManager.default.removeItem(at: home) }
        let notproton = home.appending(path: "Library/Application Support/notproton")
        let cartouche = home.appending(path: "Library/Application Support/Cartouche")
        try FileManager.default.createDirectory(at: notproton, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cartouche, withIntermediateDirectories: true)
        try Data("1.2.0\n".utf8).write(to: notproton.appending(path: "dylib.version"))
        try Data(#"{"version":"1.2.0","builtAt":1792000000}"#.utf8).write(to: notproton.appending(path: "install-build.json"))

        let ownVersion = cartouche.appending(path: "dylib.version")
        let installed = try DeploymentContent.readBuild(at: DeploymentContent.record(beside: ownVersion))
        let legacy = SteamBundle.deployedVersion(at: ownVersion)
        #expect(installed == nil && legacy == nil)
        let bundled = DeploymentContent.Build(version: "0.1.0", builtAt: 100)
        #expect(try DeploymentContent.inspect(files: [], bundled: bundled, installed: installed,
                                              legacyVersion: legacy) == .current)
        // The same record read from NotProton's folder would have refused 0.1.0
        #expect(try DeploymentContent.inspect(files: [], bundled: bundled, installed: nil,
                                              legacyVersion: SteamBundle.deployedVersion(at: notproton.appending(path: "dylib.version")))
                == .newerInstalled)
    }

    // ADR 0011: Cartouche counts 0.x from 0.1.0, not on from NotProton's 1.2.0
    @Test("version.h carries a Cartouche 0.x version, not NotProton's number")
    func versionHeader() throws {
        let header = try String(contentsOf: IdentityTests.repoRoot.appending(path: "dylib/version.h"), encoding: .utf8)
        let version = try #require(header.firstMatch(of: /#define CARTOUCHE_VERSION "([^"]+)"/)?.1).description
        #expect(version.wholeMatch(of: /\d+\.\d+\.\d+(-(beta|test)\.\d+)?/) != nil, "\(version) is not a release tag version")
        #expect(CartoucheVersion.compare(version, "1.0.0") == .orderedAscending, "\(version)")
    }
}
