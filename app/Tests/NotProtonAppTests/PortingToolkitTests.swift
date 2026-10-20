import Foundation
import Testing

@testable import NotProtonApp

// Fixture folders shaped like Apple's "Evaluation environment for Windows games"
// image, built in a scratch folder at run time. No Apple file is involved.
@Suite("Game Porting Toolkit")
final class PortingToolkitTests {

    let work: URL
    let runners: URL
    let volumes: URL

    init() throws {
        work = try scratchDirectory("gptk")
        runners = work.appending(path: "runners")
        volumes = work.appending(path: "Volumes")
        try FileManager.default.createDirectory(at: volumes, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: work) }

    static func path(_ url: URL) -> String {
        var path = url.standardizedFileURL.path(percentEncoded: false)
        while path.hasSuffix("/") { path.removeLast() }
        return path
    }

    // A lib folder as redist/lib holds it: the framework with its symlinks, the shared
    // library and the Windows side
    @discardableResult
    static func toolkit(at lib: URL, version: String = "4.0b3", plistAt plistPath: String = "Versions/A/Resources/Info.plist") throws -> URL {
        let fm = FileManager.default
        let framework = lib.appending(path: "external/D3DMetal.framework")
        try fm.createDirectory(at: framework.appending(path: "Versions/A/Resources"), withIntermediateDirectories: true)
        try Data("fixture framework binary \(version)".utf8).write(to: framework.appending(path: "Versions/A/D3DMetal"))
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleShortVersionString": version, "CFBundleIdentifier": "com.apple.D3DMetal"],
            format: .xml, options: 0)
        try fm.createDirectory(at: framework.appending(path: plistPath).deletingLastPathComponent(), withIntermediateDirectories: true)
        try plist.write(to: framework.appending(path: plistPath))
        try fm.createSymbolicLink(atPath: framework.appending(path: "Versions/Current").path(percentEncoded: false), withDestinationPath: "A")
        try fm.createSymbolicLink(atPath: framework.appending(path: "D3DMetal").path(percentEncoded: false), withDestinationPath: "Versions/Current/D3DMetal")
        try Data("fixture shared".utf8).write(to: lib.appending(path: "external/libd3dshared.dylib"))
        try fm.createDirectory(at: lib.appending(path: "wine/x86_64-windows"), withIntermediateDirectories: true)
        try Data("MZ fixture".utf8).write(to: lib.appending(path: "wine/x86_64-windows/d3d12.dll"))
        return lib
    }

    func search(applications: [URL] = [], homebrew: [URL] = [], manual: [URL] = []) -> PortingToolkitSource.Search {
        PortingToolkitSource.Search(volumes: volumes, applications: applications, homebrew: homebrew, manual: manual)
    }

    func availability(_ registry: RunnerRegistry) -> BackendAvailability {
        BackendAvailability.current(
            registry: registry, runners: runners, backends: work.appending(path: "backends"),
            manifest: RunnerManifest(format: 1, revision: 1, builds: []))
    }

    func registry(_ found: [PortingToolkitInstall], installed: [RunnerBuild] = []) -> RunnerRegistry {
        var registry = RunnerRegistry.refresh(
            runners: runners, bridge: work.appending(path: "bridge"), roots: [], manual: [], pins: [],
            fexAvailable: true, free: FreeRunnerScan(manifest: RunnerManifest(format: 1, revision: 1, builds: []), toolkits: found))
        registry.installed = installed
        registry.runners += installed.map { build in
            Runner(id: build.id, kind: .crossOver, version: build.bundleVersion,
                   displayVersion: build.displayVersion, flavors: Runner.flavors(of: build, fexAvailable: true),
                   state: .ready, build: build, source: nil, isInstalled: true)
        }
        return registry
    }

    @Test("A toolkit installed from Apple's image is found with its version, copied into the runners folder and ready")
    func found() throws {
        let volume = volumes.appending(path: "Evaluation environment for Windows games 4.0")
        try Self.toolkit(at: volume.appending(path: "redist/lib"))

        let found = PortingToolkitSource.discover(search())
        #expect(found.map(\.version) == ["4.0b3"])
        #expect(found.map { Self.path($0.origin) } == [Self.path(volume)])
        #expect(found.map { Self.path($0.lib) } == [Self.path(volume.appending(path: "redist/lib"))])
        #expect(found.allSatisfy { $0.mountedImage }, "an image under the volumes root is ejectable")
        let before = try #require(registry(found).runners.first)
        #expect(before.kind == .portingToolkit)
        #expect(before.state == .available)
        #expect(before.version == "4.0b3")

        // Only external/ is copied: the toolkit's own Wine tree is never read
        let receipt = try PortingToolkitSource.copy(try #require(found.first), runners: runners)
        #expect(Set(receipt.files.keys) == [
            "lib/external/D3DMetal.framework/Versions/A/D3DMetal",
            "lib/external/D3DMetal.framework/Versions/A/Resources/Info.plist",
            "lib/external/libd3dshared.dylib",
        ])

        let copy = PortingToolkitSource.folder(version: "4.0b3", runners: runners)
        #expect(copy.lastPathComponent == "gptk-4.0b3")
        #expect(!FileManager.default.fileExists(
            atPath: copy.appending(path: "lib/wine").path(percentEncoded: false)))
        #expect(try FileManager.default.destinationOfSymbolicLink(
            atPath: copy.appending(path: "lib/external/D3DMetal.framework/D3DMetal").path(percentEncoded: false))
            == "Versions/Current/D3DMetal")

        // The image can be ejected: the copy is what Cartouche uses
        try FileManager.default.removeItem(at: volume)
        let after = registry(PortingToolkitSource.discover(search()))
        let runner = try #require(after.runners.first)
        #expect(after.runners.count == 1)
        #expect(runner.id == "gptk-4.0b3")
        #expect(runner.state == .ready)
        #expect(runner.isInstalled)
        #expect(runner.flavors == [.rosetta])
        #expect(availability(after).d3dMetalRunners == ["gptk-4.0b3"])
        #expect(PortingToolkitSource.libd3dshared(runners: runners)
            == copy.appending(path: "lib/external/libd3dshared.dylib"))
    }

    @Test("Without a toolkit, no runner is listed and D3DMetal is not offered unless CrossOver provides it")
    func absent() throws {
        try FileManager.default.createDirectory(at: volumes.appending(path: "Steam"), withIntermediateDirectories: true)
        let found = PortingToolkitSource.discover(search())
        #expect(found.isEmpty)
        let none = registry(found)
        #expect(none.runners.filter { $0.kind == .portingToolkit }.isEmpty)
        #expect(availability(none).d3dMetalRunners.isEmpty)
        #expect(PortingToolkitSource.howToGetIt.absoluteString == "https://developer.apple.com/games/game-porting-toolkit/")

        // A set-up CrossOver clone that carries D3DMetal provides it
        let build = try #require(RunnerRegistry.build(id: "26.3.0.39832"))
        let withoutIt = registry(found, installed: [build])
        #expect(availability(withoutIt).d3dMetalRunners.isEmpty)
        let root = SupportPaths.clonedRoot(forBuild: build.id, runners: runners)
        let framework = root.appending(path: "lib64/apple_gptk/external/D3DMetal.framework")
        try FileManager.default.createDirectory(at: framework, withIntermediateDirectories: true)
        #expect(RunnerRegistry.crossOverD3DMetal(inRoot: root) == framework)
        #expect(availability(registry(found, installed: [build])).d3dMetalRunners == [build.id])
    }

    @Test("Copies in an app, a Homebrew keg or a folder the user picked are found; folders without D3DMetal are not")
    func otherPlaces() throws {
        let apps = work.appending(path: "Applications")
        let app = apps.appending(path: "Game Porting Toolkit.app")
        try Self.toolkit(at: app.appending(path: "Contents/Resources/wine/lib"), version: "3.0")
        try FileManager.default.createDirectory(at: apps.appending(path: "Porting Toolkit Notes.app"), withIntermediateDirectories: true)
        let keg = work.appending(path: "opt/game-porting-toolkit")
        try Self.toolkit(at: keg.appending(path: "lib"), version: "1.1", plistAt: "Resources/Info.plist")
        let picked = work.appending(path: "Downloads/GPTK")
        try Self.toolkit(at: picked.appending(path: "redist/lib"), version: "2.1")
        // The same version twice is copied from the first place only
        try Self.toolkit(at: volumes.appending(path: "Evaluation environment for Windows games 2.1/redist/lib"), version: "2.1")

        let found = PortingToolkitSource.discover(search(applications: [apps], homebrew: [keg], manual: [picked]))
        #expect(found.map(\.version) == ["2.1", "3.0", "1.1"])
        #expect(found.map { Self.path($0.origin) } == [picked, app, keg].map(Self.path))
        #expect(found.allSatisfy { !$0.mountedImage }, "an installed copy can be read in place")
    }

    @Test("A changed byte in the copy makes it damaged, naming the file, and copying again repairs it")
    func damage() throws {
        let volume = volumes.appending(path: "Evaluation environment for Windows games 4.0")
        try Self.toolkit(at: volume.appending(path: "redist/lib"))
        let install = try #require(PortingToolkitSource.discover(search()).first)
        try PortingToolkitSource.copy(install, runners: runners)

        let binary = PortingToolkitSource.folder(version: "4.0b3", runners: runners)
            .appending(path: "lib/external/D3DMetal.framework/Versions/A/D3DMetal")
        var bytes = try Data(contentsOf: binary)
        bytes[0] ^= 0x01
        try bytes.write(to: binary)

        let runner = try #require(registry([install]).runners.first)
        #expect(runner.state == .damaged(files: ["lib/external/D3DMetal.framework/Versions/A/D3DMetal changed since it was installed."]))
        #expect(availability(registry([install])).d3dMetalRunners.isEmpty)
        #expect(PortingToolkitSource.verify(version: runner.version, runners: runners)
            == runner.reason.map { [$0] })

        try PortingToolkitSource.copy(install, runners: runners)
        #expect(registry([install]).runners.first?.state == .ready)
    }

    @Test("An edit that keeps the file's size and stamp slips past the size check, never the hashed one")
    func stamps() throws {
        let volume = volumes.appending(path: "Evaluation environment for Windows games 4.0")
        try Self.toolkit(at: volume.appending(path: "redist/lib"))
        let install = try #require(PortingToolkitSource.discover(search()).first)
        try PortingToolkitSource.copy(install, runners: runners)

        let file = PortingToolkitSource.folder(version: "4.0b3", runners: runners)
            .appending(path: "lib/external/libd3dshared.dylib")
        let stamp = try #require(try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        var bytes = try Data(contentsOf: file)
        bytes[0] ^= 0x01
        try bytes.write(to: file)
        try FileManager.default.setAttributes(
            [.modificationDate: stamp], ofItemAtPath: file.path(percentEncoded: false))

        #expect(PortingToolkitSource.verify(version: "4.0b3", runners: runners).isEmpty)
        #expect(PortingToolkitSource.verify(version: "4.0b3", runners: runners, deep: true)
            == ["lib/external/libd3dshared.dylib changed since it was installed."])
    }

    @Test("Use in Place keeps no copy, reads the folder it recorded, and reports when it is gone")
    func inPlace() throws {
        let volume = volumes.appending(path: "Evaluation environment for Windows games 4.0")
        try Self.toolkit(at: volume.appending(path: "redist/lib"))
        let install = try #require(PortingToolkitSource.discover(search()).first)
        #expect(PortingToolkitSource.copySize(of: install.lib) > 0)

        let receipt = try PortingToolkitSource.useInPlace(install, runners: runners)
        #expect(receipt.inPlace == Self.path(install.lib))
        #expect(receipt.files.isEmpty)
        #expect(!FileManager.default.fileExists(atPath:
            PortingToolkitSource.folder(version: "4.0b3", runners: runners)
                .appending(path: "lib").path(percentEncoded: false)))

        var found = registry([install])
        var runner = try #require(found.runners.first)
        #expect(runner.state == .ready)
        #expect(runner.source.map(Self.path) == Self.path(install.lib))
        #expect(availability(found).d3dMetalRunners == ["gptk-4.0b3"])
        #expect(PortingToolkitSource.libd3dshared(runners: runners).map(Self.path)
            == Self.path(install.lib.appending(path: "external/libd3dshared.dylib")))

        // The folder goes away: the runner is damaged and names it
        try FileManager.default.removeItem(at: volume)
        found = registry(PortingToolkitSource.discover(search()))
        runner = try #require(found.runners.first)
        guard case .damaged(let files) = runner.state else {
            Issue.record("expected damaged, got \(runner.state)"); return
        }
        #expect(files == ["The folder at \(Self.path(install.lib)) is gone."])
        #expect(availability(found).d3dMetalRunners.isEmpty)
    }

    @Test("Version folders keep only safe characters")
    func ids() {
        #expect(PortingToolkitSource.runnerID(version: "4.0 beta 3") == "gptk-4.0_beta_3")
        #expect(PortingToolkitSource.runnerID(version: "../x") == "gptk-.._x")
    }
}
