import Foundation
import Testing

@testable import NotProtonApp

// Everything runs on a fixture archive in a scratch folder, served from a file URL,
// so none of this needs the network or touches the real runners folder.
@Suite("Wine runner install")
final class WineRunnerInstallerTests {

    let work: URL
    let runners: URL
    let downloads: URL
    let id = "wine-crossover-26.3.0-1"

    init() throws {
        work = try scratchDirectory("wine-runner")
        runners = work.appending(path: "runners")
        downloads = work.appending(path: "downloads")
    }

    deinit { try? FileManager.default.removeItem(at: work) }

    // An archive laid out like the CI build, with a shell script standing in for wine
    func archive(named name: String = "wine-crossover-26.3.0-1-x86_64.tar.xz", version: String = "wine-11.0 (fixture)") throws -> URL {
        let tree = work.appending(path: "tree-\(UUID().uuidString)")
        let root = tree.appending(path: id)
        let fm = FileManager.default
        for dir in ["bin", "lib/wine/x86_64-unix", "lib/wine/x86_64-windows", "lib/wine/i386-windows", "share/wine"] {
            try fm.createDirectory(at: root.appending(path: dir), withIntermediateDirectories: true)
        }
        let loader = root.appending(path: "lib/wine/x86_64-unix/wine")
        try Data("#!/bin/sh\necho '\(version)'\n".utf8).write(to: loader)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: loader.path(percentEncoded: false))
        try fm.createSymbolicLink(atPath: root.appending(path: "bin/wine").path(percentEncoded: false),
                                  withDestinationPath: "../lib/wine/x86_64-unix/wine")
        try Data("#!/bin/sh\n".utf8).write(to: root.appending(path: "bin/wineserver"))
        try Data("MZ x86_64".utf8).write(to: root.appending(path: "lib/wine/x86_64-windows/ntdll.dll"))
        try Data("MZ i386".utf8).write(to: root.appending(path: "lib/wine/i386-windows/ntdll.dll"))
        try Data("[Version]\n".utf8).write(to: root.appending(path: "share/wine/wine.inf"))
        let host = work.appending(path: "host-\(UUID().uuidString)")
        try fm.createDirectory(at: host, withIntermediateDirectories: true)
        let out = host.appending(path: name)
        try Shell.check("/usr/bin/tar", ["-cJf", out.path(percentEncoded: false), "-C", tree.path(percentEncoded: false), id])
        return out
    }

    func build(for archive: URL, sha256: String? = nil, size: Int64? = nil) throws -> RunnerManifest.Build {
        let bytes = try FileManager.default.attributesOfItem(atPath: archive.path(percentEncoded: false))[.size] as! Int64
        return RunnerManifest.Build(
            id: id, kind: "wineBuild", origin: .cartouche, name: "Wine CrossOver", version: "26.3.0",
            displayVersion: "26.3", url: archive, size: size ?? bytes, sha256: try sha256 ?? Digest.sha256(of: archive),
            root: id, loader: "bin/wine", flavors: ["rosetta"]
        )
    }

    func registry(_ builds: [RunnerManifest.Build]) -> RunnerRegistry {
        RunnerRegistry.refresh(
            runners: runners, bridge: work.appending(path: "bridge"), roots: [], manual: [], pins: [],
            fexAvailable: true, free: FreeRunnerScan(manifest: RunnerManifest(format: 1, revision: 1, builds: builds))
        )
    }

    @Test("A pinned build is downloaded, matches its SHA-256, unpacks into the runners folder, is ready and runs")
    func installPinned() async throws {
        let build = try build(for: archive())
        #expect(registry([build]).runner(id: id)?.state == .available)

        let receipt = try await WineRunnerInstaller.install(build, runners: runners, downloads: downloads)

        #expect(receipt.archiveSHA256 == build.sha256)
        #expect(Set(receipt.files.keys) == ["bin/wine", "bin/wineserver", "lib/wine/x86_64-windows/ntdll.dll", "lib/wine/i386-windows/ntdll.dll"])
        let runner = try #require(registry([build]).runner(id: id))
        #expect(runner.kind == .wineBuild)
        #expect(runner.state == .ready)
        #expect(runner.isInstalled)
        #expect(runner.flavors == [.rosetta])
        // Not offered to Steam until its ntdll is pinned and P3 lists its tools
        #expect(!runner.isOffered)
        let wine = WineRunnerInstaller.folder(for: id, runners: runners).appending(path: "bin/wine")
        #expect(try Shell.check(wine.path(percentEncoded: false), ["--version"]) == "wine-11.0 (fixture)\n")
        // The archive is not kept once unpacked, and nothing is left half done
        #expect(try FileManager.default.contentsOfDirectory(atPath: downloads.path(percentEncoded: false)).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: runners.path(percentEncoded: false)) == ["wine-\(id)"])
    }

    @Test("A download whose SHA-256 differs from the manifest is deleted, nothing is installed, and the user is told it was damaged")
    func tamperedIsRejected() async throws {
        let real = try archive()
        let build = try build(for: real)
        let tampered = try archive(version: "wine-11.0 (tampered)")
        let served = RunnerManifest.Build(
            id: build.id, kind: build.kind, origin: build.origin, name: build.name, version: build.version,
            displayVersion: build.displayVersion, url: tampered, size: build.size, sha256: build.sha256,
            root: build.root, loader: build.loader, flavors: build.flavors
        )

        do {
            try await WineRunnerInstaller.install(served, runners: runners, downloads: downloads)
            Issue.record("a tampered download was installed")
        } catch let failure as StepFailure {
            #expect(failure.detail == "The download was damaged. Try again.")
            #expect(failure.detail == WineRunnerInstaller.damaged)
        }

        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: downloads.appending(path: build.archiveName).path(percentEncoded: false)))
        #expect(((try? fm.contentsOfDirectory(atPath: downloads.path(percentEncoded: false))) ?? []).isEmpty)
        #expect(((try? fm.contentsOfDirectory(atPath: runners.path(percentEncoded: false))) ?? []).isEmpty)
        let runner = try #require(registry([build]).runner(id: id))
        #expect(runner.state == .available)
        #expect(!runner.isInstalled)
    }

    @Test("A right hash with the wrong size is refused too")
    func wrongSize() async throws {
        let archive = try archive()
        let build = try build(for: archive, size: 1)
        await #expect(throws: StepFailure.self) {
            try await WineRunnerInstaller.install(build, runners: runners, downloads: downloads)
        }
        #expect(!WineRunnerInstaller.isInstalled(id, runners: runners))
    }

    @Test("A stale or swapped archive in the downloads folder is replaced, never unpacked")
    func staleDownload() async throws {
        let build = try build(for: archive())
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        try Data("left from a broken download".utf8).write(to: downloads.appending(path: build.archiveName))
        try await WineRunnerInstaller.install(build, runners: runners, downloads: downloads)
        #expect(registry([build]).runner(id: id)?.state == .ready)

        let swapped = downloads.appending(path: "swapped.tar.xz")
        try Data("swapped".utf8).write(to: swapped)
        #expect(throws: StepFailure.self) {
            try WineRunnerInstaller.unpack(swapped, build: build, runners: runners)
        }
        #expect(!FileManager.default.fileExists(atPath: swapped.path(percentEncoded: false)))
    }

    @Test("An archive without Wine at the manifest's loader path is refused")
    func noLoader() async throws {
        let archive = try archive()
        let pinned = try build(for: archive)
        let build = RunnerManifest.Build(
            id: pinned.id, kind: pinned.kind, origin: pinned.origin, name: pinned.name, version: pinned.version,
            displayVersion: pinned.displayVersion, url: pinned.url, size: pinned.size, sha256: pinned.sha256,
            root: pinned.root, loader: "bin/wine64", flavors: pinned.flavors
        )
        await #expect(throws: StepFailure.self) {
            try await WineRunnerInstaller.install(build, runners: runners, downloads: downloads)
        }
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: runners.path(percentEncoded: false))) ?? []).isEmpty)
    }

    @Test("An unreachable download says so and installs nothing")
    func unreachable() async throws {
        let build = try build(for: archive())
        let gone = RunnerManifest.Build(
            id: build.id, kind: build.kind, origin: build.origin, name: build.name, version: build.version,
            displayVersion: build.displayVersion, url: work.appending(path: "nothing-here.tar.xz"), size: build.size,
            sha256: build.sha256, root: build.root, loader: build.loader, flavors: build.flavors
        )
        do {
            try await WineRunnerInstaller.install(gone, runners: runners, downloads: downloads)
            Issue.record("installed from nowhere")
        } catch let failure as StepFailure {
            #expect(failure.detail.hasPrefix("Cartouche could not download Wine CrossOver 26.3."))
        }
    }

    @Test("A changed byte in an installed build makes it damaged, naming the file, and installing again repairs it")
    func damageAndRepair() async throws {
        let build = try build(for: archive())
        try await WineRunnerInstaller.install(build, runners: runners, downloads: downloads)
        let ntdll = WineRunnerInstaller.folder(for: id, runners: runners).appending(path: "lib/wine/x86_64-windows/ntdll.dll")
        var bytes = try Data(contentsOf: ntdll)
        bytes[0] ^= 0x01
        try bytes.write(to: ntdll)

        let runner = try #require(registry([build]).runner(id: id))
        #expect(runner.state == .damaged(files: ["lib/wine/x86_64-windows/ntdll.dll changed since it was installed."]))
        #expect(RunnerRegistry.verify(runner, runners: runners) == ["lib/wine/x86_64-windows/ntdll.dll changed since it was installed."])

        try await WineRunnerInstaller.install(build, runners: runners, downloads: downloads)
        #expect(registry([build]).runner(id: id)?.state == .ready)
    }

    @Test("An installed build the manifest no longer pins is unsupported; removing it leaves nothing")
    func unpinnedAndRemove() async throws {
        let build = try build(for: archive())
        try await WineRunnerInstaller.install(build, runners: runners, downloads: downloads)
        let runner = try #require(registry([]).runner(id: id))
        #expect(runner.state == .unsupported(reason: "Build \(id), not supported"))
        #expect(!runner.isOffered)

        try WineRunnerInstaller.remove(id, runners: runners)
        #expect(registry([build]).runner(id: id)?.state == .available)
    }

    @Test("Free runners come after CrossOver and only when asked for")
    func onlyWhenAsked() throws {
        let build = try build(for: archive())
        let plain = RunnerRegistry.refresh(
            runners: runners, bridge: work.appending(path: "bridge"), roots: [], manual: [], pins: [], fexAvailable: true)
        #expect(plain.runners.isEmpty)
        #expect(registry([build]).runners.map(\.id) == [id])
    }
}
