import Foundation
import Testing
@testable import InstallerKit

final class RecordingRunner: ToolRunning, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls: [(tool: String, arguments: [String])] = []
    let answers: [String: String]

    init(answers: [String: String]) { self.answers = answers }

    func run(_ tool: String, _ arguments: [String]) throws -> String {
        lock.withLock { calls.append((tool, arguments)) }
        return answers[arguments[0]] ?? ""
    }
}

func executable(_ url: URL, _ script: String = "#!/bin/sh\nexit 0\n") throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try script.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path(percentEncoded: false))
}

@Suite("Innoextract")
struct InnoextractTests {

    @Test("The bundled copy wins over Homebrew, and the override wins over both")
    func lookupOrder() throws {
        let dir = try tempFolder([:])
        let bundled = dir.appending(path: "Cartouche.app/Contents/Helpers/innoextract")
        let brew = dir.appending(path: "brew/innoextract")
        let forced = dir.appending(path: "forced/innoextract")
        try executable(bundled); try executable(brew); try executable(forced)

        let p = { (env: [String: String]) in
            Innoextract.path(environment: env, bundled: [bundled], fallbacks: [brew.path(percentEncoded: false)])
        }
        #expect(p([:]) == bundled.path(percentEncoded: false))
        #expect(p(["CARTOUCHE_INNOEXTRACT": forced.path(percentEncoded: false)]) == forced.path(percentEncoded: false))
        try FileManager.default.removeItem(at: bundled)
        #expect(p([:]) == brew.path(percentEncoded: false))
        try FileManager.default.removeItem(at: brew)
        #expect(p([:]) == nil)
    }

    @Test("The app bundle's Helpers folder is a candidate")
    func helpersCandidate() {
        let names = Innoextract.bundledCandidates().map(\.path)
        #expect(names.contains { $0.hasSuffix("Contents/Helpers/innoextract") })
    }

    @Test("Inspecting calls innoextract twice with the setup as a file argument")
    func inspectCallsOnlyTheTool() throws {
        let runner = RecordingRunner(answers: [
            "--info": "Inspecting \"Sample Game\" - setup data version 5.5.0.1 (unicode)\n",
            "--list": "app/game.exe\n",
        ])
        let setup = URL(filePath: "/tmp/sample/setup.exe")
        let report = try InnoInspector.inspect(setup, tool: "/x/innoextract", runner: runner)
        #expect(report.title == "Sample Game")
        #expect(runner.calls.map(\.tool) == ["/x/innoextract", "/x/innoextract"])
        #expect(runner.calls.map(\.arguments) == [["--info", "/tmp/sample/setup.exe"], ["--list", "--silent", "/tmp/sample/setup.exe"]])
    }

    @Test("No innoextract is reported, not guessed")
    func missingTool() {
        #expect(throws: InnoInspector.Failure.toolMissing) {
            try InnoInspector.inspect(URL(filePath: "/tmp/setup.exe"), tool: nil)
        }
    }

    // innoextract reads the Inno header, warns that the stored data version is
    // not in its known list, then reports "Not a supported Inno Setup
    // installer!". The bundled build's --version says it knows Inno through
    // 6.4.0, and a Homebrew 1.9 fallback says 6.2.2.
    @Test("An Inno version above the tool's range is reported, not called not-Inno")
    func newerInnoVersion() {
        let newSetup = "Inspecting \"Next Game\" - setup data version 6.5.0\nUnexpected setup data version: 6.5.0 (unicode)\nNot a supported Inno Setup installer!\n"
        let runner = RecordingRunner(answers: [
            "--info": newSetup,
            "--version": "innoextract 1.10\nExtracts installers created by Inno Setup 1.2.10 to 6.4.0\n",
        ])
        #expect(throws: InnoInspector.Failure.newerThanSupported("6.5.0")) {
            try InnoInspector.inspect(URL(filePath: "/tmp/setup.exe"), tool: "/x/innoextract", runner: runner)
        }
        #expect(runner.calls.map(\.arguments).first == ["--info", "/tmp/setup.exe"])
        #expect(runner.calls.contains { $0.arguments == ["--version"] })
    }

    @Test("The same installer is newer-than-supported for an older tool")
    func newerInnoVersionOlderTool() {
        let newSetup = "Unexpected setup data version: 6.3.0 (unicode)\nNot a supported Inno Setup installer!\n"
        let runner = RecordingRunner(answers: [
            "--info": newSetup,
            "--version": "innoextract 1.9\nExtracts installers created by Inno Setup 1.2.10 to 6.2.2\n",
        ])
        #expect(throws: InnoInspector.Failure.newerThanSupported("6.3.0")) {
            try InnoInspector.inspect(URL(filePath: "/tmp/setup.exe"), tool: "/x/innoextract", runner: runner)
        }
    }

    @Test("A version inside the tool's range, or an unknown file, is still not-Inno")
    func unknownVersionIsNotNewer() {
        let oldSetup = "Unexpected setup data version: 1.0.0\nNot a supported Inno Setup installer!\n"
        let notInno = "Not a supported Inno Setup installer!\n"
        let runner = RecordingRunner(answers: [
            "--info": oldSetup,
            "--version": "innoextract 1.10\nExtracts installers created by Inno Setup 1.2.10 to 6.4.0\n",
        ])
        #expect(throws: InnoInspector.Failure.notInno(oldSetup)) {
            try InnoInspector.inspect(URL(filePath: "/tmp/setup.exe"), tool: "/x/innoextract", runner: runner)
        }
        let other = RecordingRunner(answers: ["--info": notInno])
        #expect(throws: InnoInspector.Failure.notInno(notInno)) {
            try InnoInspector.inspect(URL(filePath: "/tmp/setup.exe"), tool: "/x/innoextract", runner: other)
        }
    }
}
