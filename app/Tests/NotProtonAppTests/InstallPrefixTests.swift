import Foundation
import InstallerKit
import Testing

@testable import NotProtonApp

func fakeRunner(in runners: URL, build: String = "27.0.0.40921", flavors: [CompatTool.Flavor] = [.rosetta, .fex]) throws -> Runner {
    let pinned = try #require(RunnerRegistry.build(id: build))
    let wine = SupportPaths.clonedRoot(forBuild: build, runners: runners).appending(path: "lib/wine/x86_64-unix/wine")
    try FileManager.default.createDirectory(at: wine.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: wine)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wine.path)
    return Runner(id: build, kind: .crossOver, version: build, displayVersion: build, flavors: flavors,
                  state: .ready, build: pinned, source: nil, isInstalled: true)
}

@Suite("Install prefix")
struct InstallPrefixTests {

    @Test("Each game gets its own folder and a fresh prefix")
    func freshPerGame() throws {
        let installs = try scratchDirectory("installs")
        let a = try GameFolder.fresh(for: "Sample Game: Part II", in: installs)
        let b = try GameFolder.fresh(for: "Other Game", in: installs)
        #expect(a.root.lastPathComponent == "sample-game-part-ii")
        #expect(b.root.lastPathComponent == "other-game")
        #expect(FileManager.default.fileExists(atPath: a.prefix.path))
        #expect(a.prefix != b.prefix)
    }

    @Test("A retry clears its unfinished attempt; a finished game is never reused")
    func retryAndFinished() throws {
        let installs = try scratchDirectory("installs")
        let first = try GameFolder.fresh(for: "Sample", in: installs)
        try Data("left from the failed run".utf8).write(to: first.prefix.appending(path: "system.reg"))
        let retry = try GameFolder.fresh(for: "Sample", in: installs)
        #expect(retry == first)
        #expect(!FileManager.default.fileExists(atPath: retry.prefix.appending(path: "system.reg").path))

        try Data("{}".utf8).write(to: retry.record)
        let again = try GameFolder.fresh(for: "Sample", in: installs)
        #expect(again.root.lastPathComponent == "sample-2")
        #expect(FileManager.default.fileExists(atPath: retry.record.path))
    }

    @Test("A folder Cartouche did not mark is left alone")
    func foreignFolderKept() throws {
        let installs = try scratchDirectory("installs")
        let foreign = installs.appending(path: "sample")
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: foreign.appending(path: "notes.txt"))
        let folder = try GameFolder.fresh(for: "Sample", in: installs)
        #expect(folder.root.lastPathComponent == "sample-2")
        #expect(FileManager.default.fileExists(atPath: foreign.appending(path: "notes.txt").path))
    }

    @Test("The install uses the runner's x86_64 Wine, so it runs under Rosetta")
    func rosettaWine() throws {
        let runners = try scratchDirectory("runners")
        let runner = try fakeRunner(in: runners)
        let wine = try #require(InstallRunners.wine(for: runner, runners: runners))
        #expect(wine.loader.path.hasSuffix("crossover-27.0.0.40921/CrossOver/lib/wine/x86_64-unix/wine"))
        #expect(wine.dllPath.hasSuffix("lib/wine/x86_64-windows:" + wine.root.appending(path: "lib/wine/x86_64-unix").path))

        let launch = WineInstall.runSetup(URL(filePath: "/x/setup.exe"), runner: wine, prefix: URL(filePath: "/p"),
                                          inputs: InstallInputs(runnerID: runner.id, gameName: "X"), base: [:])
        #expect(Array(launch.arguments.prefix(2)) == ["-x86_64", wine.loader.path])
    }

    @Test("A runner without Rosetta or without Wine on disk is not offered for installs")
    func choices() throws {
        let runners = try scratchDirectory("runners")
        let ready = try fakeRunner(in: runners)
        let fexOnly = Runner(id: "f", kind: .crossOver, version: "f", displayVersion: "f", flavors: [.fex],
                             state: .ready, build: ready.build, source: nil, isInstalled: true)
        #expect(InstallRunners.choices(RunnerRegistry(runners: [ready, fexOnly])).map(\.id) == [ready.id])
        #expect(InstallRunners.wine(for: ready, runners: try scratchDirectory("empty")) == nil)
    }
}
