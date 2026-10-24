import Darwin
import Foundation
import Testing
@testable import InstallerKit

@Suite("procargs probe")
struct ProcArgsProbeTests {

    @Test("A spawned process's command line is readable for the journal")
    func commandLine() throws {
        let p = Process()
        p.executableURL = URL(filePath: "/bin/sleep")
        p.arguments = ["5"]
        p.environment = ["WINEPREFIX": "/tmp/xyz123"]
        try p.run()
        defer { p.terminate() }
        Thread.sleep(forTimeInterval: 0.2)
        let line = ProcessGroup.commandLine(of: p.processIdentifier)
        #expect(line?.contains("sleep") == true, Comment(rawValue: "line=\(line ?? "nil")"))
    }

    @Test("A reparented process is still readable by command line even though no API names its prefix")
    func reparentedTracked() throws {
        // The monitor's seen-pid set is what survives reparenting on macOS: a helper whose
        // parent exited is no longer a descendant but its identity stays readable.
        let script = "#!/bin/sh\n/bin/sh -c 'sleep 3' &\nexit 0\n"
        let file = try tempFolder([:]).appending(path: "s.sh")
        try executable(file, script)
        let p = Process()
        p.executableURL = URL(filePath: "/bin/sh")
        p.arguments = [file.path(percentEncoded: false)]
        try p.run()
        p.waitUntilExit()
        Thread.sleep(forTimeInterval: 0.3)
        let orphans = ProcessGroup.allPIDs().filter { pid in
            (ProcessGroup.commandLine(of: pid) ?? "").contains("sleep 3")
        }
        defer { for pid in orphans { kill(pid, SIGKILL) } }
        #expect(!orphans.isEmpty)
    }
}
