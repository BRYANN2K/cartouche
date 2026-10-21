import Foundation
import Testing
@testable import InstallerKit

@Suite("Verification evidence")
struct VerificationKitTests {

    @Test("--list-sizes parses promised file sizes, skipping noise")
    func listSizes() throws {
        let dir = try tempFolder(["setup.exe": "MZ"])
        let setup = dir.appending(path: "setup.exe")
        let out = "1024 app\\game.exe\n  2048 app\\data\\data.bin\ncomment line\nabc notanumber\n0 app\\zero.dat\n\n"
        let runner = RecordingRunner(answers: ["--list-sizes": out])
        let entries = try InnoInspector.listSizes(setup, tool: "/bin/echo", runner: runner)
        #expect(entries == [
            InnoFileEntry(path: #"app\game.exe"#, bytes: 1024),
            InnoFileEntry(path: #"app\data\data.bin"#, bytes: 2048),
            InnoFileEntry(path: #"app\zero.dat"#, bytes: 0),
        ])
        #expect(runner.calls.map(\.arguments) == [["--list-sizes", "--silent", setup.path(percentEncoded: false)]])
    }

    @Test("A missing tool or a non-Inno setup fails instead of an empty list")
    func listSizesFailures() throws {
        let dir = try tempFolder(["setup.exe": "MZ"])
        let setup = dir.appending(path: "setup.exe")
        #expect(throws: InnoInspector.Failure.toolMissing) {
            try InnoInspector.listSizes(setup, tool: nil, runner: RecordingRunner(answers: [:]))
        }
        let runner = RecordingRunner(answers: ["--list-sizes": "Not a supported Inno Setup installer"])
        #expect(throws: InnoInspector.Failure.notInno("Not a supported Inno Setup installer")) {
            try InnoInspector.listSizes(setup, tool: "/bin/echo", runner: runner)
        }
    }

    @Test("The empty allowlist replaces nothing; unknown helpers never get a native stand-in")
    func helperAllowlist() throws {
        let dir = try tempFolder(["unarc.dll": "helper-bytes"])
        let helper = dir.appending(path: "unarc.dll")
        #expect(HelperAllowlist.replacements.isEmpty)
        #expect(HelperAllowlist.nativeReplacement(for: helper) == nil)
        #expect(HelperAllowlist.nativeReplacement(for: dir.appending(path: "missing.dll")) == nil)
        #expect(HelperAllowlist.sha256(of: helper)?.count == 64)
        #expect(HelperAllowlist.sha256(of: dir.appending(path: "missing.dll")) == nil)
    }
}
