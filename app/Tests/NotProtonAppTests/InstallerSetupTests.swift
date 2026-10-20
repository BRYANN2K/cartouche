import Foundation
import InstallerKit
import Testing

@testable import NotProtonApp

// Fixture runners and scratch folders only: no CrossOver, Steam or ~/Library
// folder is read.
@MainActor
@Suite("Installer game setup")
struct InstallerSetupTests {

    // A ready free Wine build, as the registry lists it: installed but not
    // offered to Steam. Its loader lives in runners/wine-<id>/bin/wine.
    static func freeWine(_ id: String, version: String? = nil, in runners: URL) throws -> Runner {
        let loader = WineRunnerInstaller.folder(for: id, runners: runners).appending(path: "bin/wine")
        try FileManager.default.createDirectory(at: loader.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: loader)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: loader.path)
        return Runner(id: id, kind: .wineBuild, version: version ?? id, displayVersion: version ?? id,
                      flavors: [.rosetta], state: .ready, build: nil, source: nil, isInstalled: true)
    }

    // A DXMT backend already "downloaded": receipt plus its DLL folders
    static func dxmt(in backends: URL) throws {
        try backend(.dxmt, in: backends)
        try Data("metal dll".utf8).write(to: BackendInstaller.folder(for: .dxmt, in: backends)
            .appending(path: "x86_64-windows/winemetal.dll"))
    }

    static func backend(_ kind: GraphicsBackend, in backends: URL) throws {
        let root = BackendInstaller.folder(for: kind, in: backends)
        try FileManager.default.createDirectory(at: root.appending(path: "x86_64-windows"), withIntermediateDirectories: true)
        let receipt = BackendInstaller.Receipt(backend: kind, version: "0.80",
                                               archiveSHA256: String(repeating: "a", count: 64), files: [:])
        try JSONEncoder().encode(receipt).write(to: root.appending(path: BackendInstaller.receiptName))
    }

    // A finished install in a scratch installs/ folder
    static func installed(in installs: URL, name: String = "Sample", runnerID: String = "wine-11.0",
                          wineVersion: String? = "11.0", wineRunnerKind: String? = "wineBuild") throws -> GameFolder {
        let folder = try GameFolder.fresh(for: name, in: installs)
        let fm = FileManager.default
        let exe = folder.prefix.appending(path: "drive_c/Games/Sample/game.exe")
        try fm.createDirectory(at: folder.prefix.appending(path: "drive_c/windows/system32"), withIntermediateDirectories: true)
        try fm.createDirectory(at: exe.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("MZ".utf8).write(to: exe)
        try Data("reg".utf8).write(to: folder.prefix.appending(path: "system.reg"))
        let record = InstalledGame(id: folder.root.lastPathComponent, name: name, appID: nil, gogID: nil,
                                   runnerID: runnerID, graphics: GraphicsBackend.wined3d.rawValue,
                                   wineVersion: wineVersion, wineRunnerKind: wineRunnerKind,
                                   prefix: folder.prefix.path(percentEncoded: false),
                                   exe: exe.path(percentEncoded: false), installedAt: Date(),
                                   installerFolder: "/x", redistributables: [])
        try InstalledGames.save(record, in: folder)
        return folder
    }

    // The library model pointed at scratch folders, with the install listed
    static func model(in work: URL, installs: URL, runners: [Runner],
                      runnersFolder: URL, backends: URL) -> LibraryModel {
        let model = LibraryModel(store: LibraryStore(folder: work.appending(path: "library")),
                                 defaults: ScratchDefaults().defaults)
        model.runners = runners
        model.installsFolder = installs
        model.runnersFolder = runnersFolder
        model.backendsFolder = backends
        // DXMT is offered on Wine built from CrossOver's sources; mark the fixtures so
        model.backendAvailability = BackendAvailability(installed: [.dxmt], crossOverWine: Set(runners.map(\.id)))
        model.showInstalledGames(InstalledGames.all(in: installs))
        return model
    }

    static func record(in folder: GameFolder) -> InstalledGame? {
        (try? Data(contentsOf: folder.record)).flatMap { try? RecordCoding.decoder.decode(InstalledGame.self, from: $0) }
    }

    static func snapshot(_ root: URL) throws -> [String: String] {
        var out: [String: String] = [:]
        for rel in try FileManager.default.subpathsOfDirectory(atPath: root.path(percentEncoded: false)) {
            let file = root.appending(path: rel)
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: file.path(percentEncoded: false), isDirectory: &isDir)
            guard !isDir.boolValue else { continue }
            out[rel] = String(decoding: (try? Data(contentsOf: file)) ?? Data(), as: UTF8.self)
        }
        return out
    }

    @Test("A non-CrossOver Wine gets the backend DLLs first in WINEDLLPATH; CrossOver gets CX_GRAPHICS_BACKEND only")
    func environmentPerPair() throws {
        let work = try scratchDirectory("installer-env")
        defer { try? FileManager.default.removeItem(at: work) }
        let backends = work.appending(path: "backends")
        try Self.dxmt(in: backends)
        let runners = work.appending(path: "runners")
        let free = try Self.freeWine("wine-11.0", in: runners)
        let wine = try #require(InstallRunners.wine(for: free, runners: runners))
        let prefix = work.appending(path: "pfx")

        let env = SetupEnvironment.make(wine: wine, prefix: prefix, backend: .dxmt, backends: backends, base: [:])
        #expect(env["CX_GRAPHICS_BACKEND"] == "dxmt")
        let dxmtFolder = BackendInstaller.folder(for: .dxmt, in: backends).appending(path: "x86_64-windows")
        #expect(env["WINEDLLPATH"]?.hasPrefix(dxmtFolder.path(percentEncoded: false)) == true)
        // The menu-builder block stays first, the DXMT builtins are appended
        #expect(env["WINEDLLOVERRIDES"] == "winemenubuilder.exe=d;d3d11,dxgi,d3d10core=b")

        // A CrossOver root has share/crossover: its own backend, no Cartouche DLLs
        let root = work.appending(path: "crossover")
        try FileManager.default.createDirectory(at: root.appending(path: "share/crossover"), withIntermediateDirectories: true)
        let crossOver = WineRunner(root: root, loader: root.appending(path: "bin/wine"),
                                   server: root.appending(path: "bin/wineserver"), dllPath: "x:y")
        let cx = SetupEnvironment.make(wine: crossOver, prefix: prefix, backend: .dxmt, backends: backends, base: [:])
        #expect(cx["CX_GRAPHICS_BACKEND"] == "dxmt")
        #expect(cx["WINEDLLPATH"] == "x:y")
        #expect(cx["WINEDLLOVERRIDES"] == "winemenubuilder.exe=d")

        let plain = SetupEnvironment.make(wine: wine, prefix: prefix, backend: .wined3d, backends: backends, base: [:])
        #expect(plain["CX_GRAPHICS_BACKEND"] == "wined3d")
        #expect(plain["WINEDLLOVERRIDES"] == "winemenubuilder.exe=d")
    }

    @Test("D3DMetal on a free Wine points at the installed toolkit's libd3dshared; without one nothing is set")
    func d3dMetalEnvironment() throws {
        let work = try scratchDirectory("installer-d3dm")
        defer { try? FileManager.default.removeItem(at: work) }
        let backends = work.appending(path: "backends")
        let runners = work.appending(path: "runners")
        let wine = try #require(InstallRunners.wine(for: Self.freeWine("wine-11.0", in: runners), runners: runners))
        let prefix = work.appending(path: "pfx")

        var env = SetupEnvironment.make(
            wine: wine, prefix: prefix, backend: .d3dmetal, backends: backends, runners: runners, base: [:])
        #expect(env["CX_GRAPHICS_BACKEND"] == "d3dmetal")
        #expect(env["CX_APPLEGPTK_LIBD3DSHARED_PATH"] == nil)

        let lib = try PortingToolkitTests.toolkit(at: work.appending(path: "redist/lib"), version: "4.0b3")
        try PortingToolkitSource.copy(
            PortingToolkitInstall(lib: lib, version: "4.0b3", origin: work), runners: runners)
        env = SetupEnvironment.make(
            wine: wine, prefix: prefix, backend: .d3dmetal, backends: backends, runners: runners, base: [:])
        #expect(env["CX_APPLEGPTK_LIBD3DSHARED_PATH"] == runners
            .appending(path: "gptk-4.0b3/lib/external/libd3dshared.dylib").path(percentEncoded: false))
        #expect(env["WINEDLLOVERRIDES"] == "winemenubuilder.exe=d")
    }

    @Test("The run script overrides the same backend DLLs the app's environment does")
    func overrideListsMatchTheScript() throws {
        let work = try scratchDirectory("installer-overrides")
        defer { try? FileManager.default.removeItem(at: work) }
        let backends = work.appending(path: "backends")
        try Self.backend(.dxmt, in: backends)
        try Self.backend(.dxvk, in: backends)
        let root = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let script = try String(contentsOf: root.appending(path: "dylib/feats/compat_run.sh"), encoding: .utf8)
        let dxmt = try #require(script.firstMatch(of: /dxmt\) np_backend_dlls="([^"]+)"/)).1
        let other = try #require(script.firstMatch(of: /\*\) np_backend_dlls="([^"]+)"/)).1
        for (kind, shell) in [(GraphicsBackend.dxmt, String(dxmt)), (.dxvk, String(other))] {
            let overrides = try #require(SetupEnvironment.dlls(kind, backends: backends)?.overrides)
            #expect(overrides == "\(shell)=b", "\(kind) DLL list")
        }
    }

    @Test("DXMT copies winemetal.dll into the prefix's system32; DXVK and a missing receipt do not")
    func dxmtCopiesDll() throws {
        let work = try scratchDirectory("installer-dxmt")
        defer { try? FileManager.default.removeItem(at: work) }
        let backends = work.appending(path: "backends")
        try Self.dxmt(in: backends)
        let system32 = work.appending(path: "pfx/drive_c/windows/system32")
        try FileManager.default.createDirectory(at: system32, withIntermediateDirectories: true)
        let target = system32.appending(path: "winemetal.dll")

        SetupEnvironment.prepare(.dxvk, prefix: work.appending(path: "pfx"), backends: backends)
        #expect(!FileManager.default.fileExists(atPath: target.path(percentEncoded: false)))
        SetupEnvironment.prepare(.dxmt, prefix: work.appending(path: "pfx"), backends: backends)
        #expect(String(decoding: try Data(contentsOf: target), as: UTF8.self) == "metal dll")
        // A missing backend folder leaves the prefix alone
        SetupEnvironment.prepare(.dxmt, prefix: work.appending(path: "pfx"), backends: work.appending(path: "empty"))
        #expect(String(decoding: try Data(contentsOf: target), as: UTF8.self) == "metal dll")
    }

    @Test("The picker offers the install runners: a ready free Wine build included, GPTK and unready runners excluded")
    func pickerOffering() throws {
        let work = try scratchDirectory("installer-pool")
        defer { try? FileManager.default.removeItem(at: work) }
        let runners = work.appending(path: "runners")
        let free = try Self.freeWine("wine-11.0", in: runners)
        let crossOver = try fakeRunner(in: runners)
        let gptk = Runner(id: "gptk-3.0", kind: .portingToolkit, version: "3.0", displayVersion: "3.0",
                          flavors: [.rosetta], state: .ready, build: nil, source: nil, isInstalled: true)
        let downloading = Runner(id: "wine-10.0", kind: .wineBuild, version: "10.0", displayVersion: "10.0",
                                 flavors: [.rosetta], state: .available, build: nil, source: nil, isInstalled: false)
        let model = Self.model(in: work, installs: work.appending(path: "installs"),
                               runners: [free, crossOver, gptk, downloading],
                               runnersFolder: runners, backends: work.appending(path: "backends"))
        #expect(Set(model.installRunners.map(\.id)) == [free.id, crossOver.id])
        // The free build is still not what Steam gets offered
        #expect(!model.runners.filter(\.isOffered).contains { $0.id == free.id })
    }

    @Test("With no stored choice the install's own runner and backend resolve; the choice is then persisted")
    func defaultFromInstallAndPersistence() throws {
        let work = try scratchDirectory("installer-default")
        defer { try? FileManager.default.removeItem(at: work) }
        let installs = work.appending(path: "installs")
        let runners = work.appending(path: "runners")
        let free = try Self.freeWine("wine-11.0", in: runners)
        _ = try Self.installed(in: installs)
        let model = Self.model(in: work, installs: installs, runners: [free],
                               runnersFolder: runners, backends: work.appending(path: "backends"))
        let game = try #require(model.game("installer:sample"))

        let resolved = model.resolution(for: game)
        #expect(resolved.setup.runner?.id == "wine-11.0")
        #expect(resolved.setup.backend == .wined3d)
        #expect(resolved.setup.translation == .rosetta)

        model.setSetup(GameSetupChoice(graphics: .dxmt), for: game.id)
        #expect(model.setup(for: game.id).graphics == .dxmt)
        let store = LibraryStore(folder: work.appending(path: "library"))
        #expect(store.load().setups[game.id]?.graphics == .dxmt)
        // Nothing was sent to Steam's compatibility requests
        #expect(!FileManager.default.fileExists(atPath: model.compatRequestsFile.path(percentEncoded: false)))
    }

    @Test("Applying a setup rewrites the launcher, updates the record and touches no game or prefix file")
    func applyRewritesInPlace() throws {
        let work = try scratchDirectory("installer-apply")
        defer { try? FileManager.default.removeItem(at: work) }
        let installs = work.appending(path: "installs")
        let runners = work.appending(path: "runners")
        let backends = work.appending(path: "backends")
        try Self.dxmt(in: backends)
        let old = try Self.freeWine("wine-11.0", version: "11.0", in: runners)
        let new = try Self.freeWine("wine-12.0", version: "12.0", in: runners)
        let folder = try Self.installed(in: installs)
        let before = try Self.snapshot(folder.prefix)
        let model = Self.model(in: work, installs: installs, runners: [old, new],
                               runnersFolder: runners, backends: backends)
        let game = try #require(model.game("installer:sample"))

        model.setSetup(GameSetupChoice(runnerID: "wine-12.0", graphics: .dxmt), for: game.id)
        #expect(model.problem == nil)

        // The launcher now starts the new Wine with the DXMT environment
        let script = try String(contentsOf: folder.launcher, encoding: .utf8)
        #expect(script.contains("wine-12.0/bin/wine"))
        #expect(script.contains("CX_GRAPHICS_BACKEND"))
        #expect(script.contains("WINEDLLOVERRIDES"))
        // winemetal.dll landed in the same prefix
        #expect(FileManager.default.fileExists(
            atPath: folder.prefix.appending(path: "drive_c/windows/system32/winemetal.dll").path(percentEncoded: false)))
        let record = try #require(Self.record(in: folder))
        #expect(record.runnerID == "wine-12.0")
        #expect(record.graphics == "dxmt")
        #expect(record.wineVersion == "12.0")
        #expect(record.wineRunnerKind == "wineBuild")
        var after = try Self.snapshot(folder.prefix)
        after["drive_c/windows/system32/winemetal.dll"] = nil
        #expect(after == before)
    }

    @Test("An older Wine than the one that last ran the prefix warns and still applies")
    func olderWineWarns() throws {
        let work = try scratchDirectory("installer-older")
        defer { try? FileManager.default.removeItem(at: work) }
        let installs = work.appending(path: "installs")
        let runners = work.appending(path: "runners")
        let old = try Self.freeWine("wine-10.0", version: "10.0", in: runners)
        let new = try Self.freeWine("wine-11.0", version: "11.0", in: runners)
        let folder = try Self.installed(in: installs)
        let model = Self.model(in: work, installs: installs, runners: [old, new],
                               runnersFolder: runners, backends: work.appending(path: "backends"))
        let game = try #require(model.game("installer:sample"))

        model.setSetup(GameSetupChoice(runnerID: "wine-10.0"), for: game.id)
        #expect(model.setupNotices[game.id] != nil)
        #expect(Self.record(in: folder)?.runnerID == "wine-10.0")
        // Switching back to the newer Wine clears the note and warns no more
        model.setSetup(GameSetupChoice(runnerID: "wine-11.0"), for: game.id)
        #expect(model.setupNotices[game.id] == nil)
        #expect(Self.record(in: folder)?.wineVersion == "11.0")
    }
}
