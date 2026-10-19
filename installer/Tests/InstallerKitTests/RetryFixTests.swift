import Foundation
import Testing
@testable import InstallerKit

@Suite("Retry fixes")
struct RetryFixTests {

    let base = InstallInputs(runnerID: "runner-a", gameName: "Sample Game Deluxe", language: "en")
    let setup = URL(filePath: "/Volumes/Data/Sample Installer/setup.exe")
    let prefix = URL(filePath: "/S/installs/sample/pfx")

    private func launch(_ inputs: InstallInputs) -> InstallLaunch {
        WineInstall.runSetup(setup, runner: sampleRunner, prefix: prefix, inputs: inputs, base: [:])
    }

    @Test("Every fix changes the next run's inputs", arguments: RetryFix.allCases)
    func everyFixChangesInputs(fix: RetryFix) throws {
        let next = try #require(base.applying(fix, cores: 10, runners: ["runner-a", "runner-b"]))
        #expect(next != base)
    }

    @Test("Verify Files checks the parts again before the next run")
    func verify() throws {
        let next = try #require(base.applying(.verifyFiles))
        #expect(next.verifyFirst)
        #expect(next.applying(.verifyFiles) == nil)
    }

    @Test("Fewer Threads halves the cores Wine shows the installer, down to one")
    func threads() throws {
        let next = try #require(base.applying(.fewerThreads, cores: 10))
        #expect(next.threads == 5)
        #expect(launch(next).environment["WINE_CPU_TOPOLOGY"] == "5:0,1,2,3,4")
        #expect(launch(base).environment["WINE_CPU_TOPOLOGY"] == nil)
        var one = base; one.threads = 1
        #expect(one.applying(.fewerThreads) == nil)
    }

    @Test("Less Memory steps the decompressors' limit down from 75% to 25%")
    func memory() throws {
        let a = try #require(base.applying(.lessMemory))
        let b = try #require(a.applying(.lessMemory))
        let c = try #require(b.applying(.lessMemory))
        #expect([a, b, c].map(\.memoryPercent) == [50, 35, 25])
        #expect(c.applying(.lessMemory) == nil)
    }

    @Test("Short Path installs to C:\\G\\<8 letters> and runs setup from drive S")
    func shortPath() throws {
        let next = try #require(base.applying(.shortPath))
        #expect(next.installDir == #"C:\G\SampleGa"#)
        #expect(next.shortSource)
        let args = launch(next).arguments
        #expect(args.contains(#"S:\setup.exe"#))
        #expect(args.contains(#"/DIR=C:\G\SampleGa"#))
        #expect(next.applying(.shortPath) == nil)
    }

    @Test("Other Runner moves to the next runner, then has nothing left")
    func otherRunner() throws {
        let next = try #require(base.applying(.otherRunner, runners: ["runner-a", "runner-b"]))
        #expect(next.runnerID == "runner-b")
        #expect(next.applying(.otherRunner, runners: ["runner-a", "runner-b"]) == nil)
        #expect(base.applying(.otherRunner, runners: ["runner-a"]) == nil)
    }

    @Test("CLS.ini limits are rewritten, the rest is kept")
    func clsPatch() {
        let ini = "[Common]\r\nTempPath={app}\r\nMemory=75%\r\nThreads=100%\r\n; comment\r\n[srep]\r\nMaxMemory=75%\r\n"
        let out = CLSConfig.patched(ini, memoryPercent: 35, threads: 4)
        #expect(out == "[Common]\r\nTempPath={app}\r\nMemory=35%\r\nThreads=4\r\n; comment\r\n[srep]\r\nMaxMemory=35%\r\n")
        #expect(CLSConfig.patched(ini, memoryPercent: nil, threads: nil) == ini)
    }

    @Test("The CLS.ini the installer unpacks in the prefix's temp folder is patched once")
    func clsInPrefix() throws {
        let pfx = try tempFolder([
            "drive_c/users/crossover/Temp/is-4F2KD.tmp/CLS.ini": "[Common]\nMemory=75%\nThreads=100%\n",
            "drive_c/users/crossover/Temp/is-4F2KD.tmp/readme.ini": "Memory=75%\n",
        ])
        var inputs = base; inputs.memoryPercent = 50
        var done: Set<String> = []
        let changed = CLSConfig.apply(in: pfx, inputs: inputs, done: &done)
        #expect(changed.map(\.lastPathComponent) == ["CLS.ini"])
        let text = try String(contentsOf: changed[0], encoding: .utf8)
        #expect(text == "[Common]\nMemory=50%\nThreads=100%\n")
        #expect(CLSConfig.apply(in: pfx, inputs: inputs, done: &done).isEmpty)
        #expect(try String(contentsOf: pfx.appending(path: "drive_c/users/crossover/Temp/is-4F2KD.tmp/readme.ini"), encoding: .utf8) == "Memory=75%\n")
    }
}
