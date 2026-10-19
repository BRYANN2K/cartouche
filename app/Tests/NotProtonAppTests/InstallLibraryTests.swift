import Foundation
import SwiftUI
import Testing

@testable import NotProtonApp

@MainActor
@Suite("Installer in the library")
struct InstallLibraryTests {

    @Test("A finished install is listed under Windows Installers with its exe and Steam App ID")
    func listed() throws {
        let work = try scratchDirectory("installer-library")
        let defaults = ScratchDefaults()
        let model = LibraryModel(store: LibraryStore(folder: work), defaults: defaults.defaults)
        model.otherGames = [Game(id: "console:x", source: .console("NES"), name: "Console Game", installed: true)]

        let installs = work.appending(path: "installs")
        let folder = try GameFolder.fresh(for: "Sample Game", in: installs)
        let game = InstalledGame(id: folder.root.lastPathComponent, name: "Sample Game", appID: 632_470, runnerID: "r",
                                 prefix: folder.prefix.path, exe: folder.prefix.appending(path: "drive_c/Games/Sample Game/game.exe").path,
                                 installedAt: Date(), installerFolder: "/x", redistributables: ["d3dx9"])
        try InstalledGames.save(game, in: folder)
        #expect(!FileManager.default.fileExists(atPath: folder.attempt.path))

        model.showInstalledGames(InstalledGames.all(in: installs))
        model.showInstalledGames(InstalledGames.all(in: installs))
        let listed = model.games(in: .source(.installer))
        #expect(listed.map(\.name) == ["Sample Game"])
        #expect(listed.first?.steamAppID == 632_470)
        #expect(listed.first?.installed == true)
        #expect(listed.first?.executable?.lastPathComponent == "game.exe")
        #expect(model.otherGames.contains { $0.source == .console("NES") })
    }

    @Test("Add Games for Windows opens the install sheet, not the Add Games sheet")
    func windowsKindIsFiltered() {
        var kind: AddGamesKind? = .windows
        let binding = Binding(get: { kind }, set: { kind = $0 })
        #expect(binding.withoutWindows.wrappedValue == nil)
        kind = .consoles
        #expect(binding.withoutWindows.wrappedValue == .consoles)
        binding.withoutWindows.wrappedValue = nil
        #expect(kind == nil)
    }

    @Test("Opening the center without a folder shows the drop step")
    func openDrop() {
        let center = InstallCenter(notifier: RecordingNotifier())
        center.open()
        #expect(center.isSheetPresented)
        #expect(center.sheet.step == .drop)
    }

    @Test("A ready free Wine build can run installs, with its own Wine")
    func freeWineBuild() throws {
        let runners = try scratchDirectory("runners")
        let loader = WineRunnerInstaller.folder(for: "wine-11.0", runners: runners).appending(path: "bin/wine")
        try FileManager.default.createDirectory(at: loader.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: loader)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: loader.path)
        let runner = Runner(id: "wine-11.0", kind: .wineBuild, version: "11.0", displayVersion: "11.0", flavors: [.rosetta],
                            state: .ready, build: nil, source: nil, isInstalled: true)
        #expect(InstallRunners.choices(RunnerRegistry(runners: [runner])).map(\.id) == ["wine-11.0"])
        #expect(InstallRunners.wine(for: runner, runners: runners)?.loader.path == loader.path)
    }
}
