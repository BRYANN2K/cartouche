import Foundation
import Testing
@testable import InstallerKit

// Synthetic logs in the format Inno Setup 5.5 writes with /LOG. They are written
// for these tests, not copied from a real install.
private func fixture(_ name: String) -> String? {
    InstallLog.read(URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/logs/\(name).log"))
}

@Suite("Install log")
struct InstallLogTests {

    @Test("An unarc.dll error names memory, path, damaged file in that order and offers the three retries")
    func unarc() {
        let d = InstallLog.diagnose(exitCode: 0, log: fixture("unarc-error"))
        #expect(d.kind == .decompression)
        #expect(d.causes == [.memory, .path, .damagedFile])
        #expect(Array(d.fixes.prefix(3)) == [.verifyFiles, .fewerThreads, .lessMemory])
        #expect(d.detail == "An error occurred while unpacking: Unarc.dll returned an error code: -11")
        #expect(!d.succeeded)
    }

    @Test("An ISDone.dll error is a decompression error too")
    func isdone() {
        let d = InstallLog.diagnose(exitCode: 1, log: fixture("isdone-error"))
        #expect(d.kind == .decompression)
        #expect(d.causes == [.memory, .path, .damagedFile])
        #expect(d.detail == "ISDone.dll: It is not found any file specified for ISArcExtract")
    }

    @Test("A full disk is named as such, not as memory")
    func diskFull() {
        let d = InstallLog.diagnose(exitCode: 0, log: fixture("disk-full"))
        #expect(d.kind == .diskSpace)
        #expect(d.causes == [.diskSpace])
    }

    @Test("A clean log with exit 0 succeeds, even though it names unarc.dll")
    func success() {
        #expect(InstallLog.diagnose(exitCode: 0, log: fixture("success")).succeeded)
        #expect(InstallLog.diagnose(exitCode: 0, log: nil).succeeded)
    }

    @Test("Cancel is not a failure to diagnose", arguments: [Int32(2), 5])
    func cancelled(code: Int32) {
        #expect(InstallLog.diagnose(exitCode: code, log: fixture("cancelled")).kind == .cancelled)
        #expect(InstallLog.diagnose(exitCode: code, log: nil).kind == .cancelled)
    }

    @Test("Another exit code points at the runner and the path")
    func fatal() {
        let d = InstallLog.diagnose(exitCode: 4, log: fixture("fatal"))
        #expect(d.kind == .setupFailed)
        #expect(d.fixes == [.otherRunner, .shortPath])
        #expect(d.detail == "Fatal exception during installation process (EAccessViolation):")
    }

    @Test("Inno's own corrupted-files message asks to verify the files")
    func damaged() {
        let d = InstallLog.diagnose(exitCode: 1, log: "The setup files are corrupted. Please obtain a new copy of the program.")
        #expect(d.kind == .damagedFile)
        #expect(d.fixes == [.verifyFiles])
    }

    @Test("A UTF-16 log is read")
    func utf16() throws {
        let url = try tempFolder([:]).appending(path: "installer.log")
        var data = Data([0xFF, 0xFE])
        data.append("Unarc.dll returned an error code: -1\r\n".data(using: .utf16LittleEndian)!)
        try data.write(to: url)
        #expect(InstallLog.diagnose(exitCode: 0, log: InstallLog.read(url)).kind == .decompression)
    }
}
