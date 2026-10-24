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

    @Test("unarc -11 is explained as memory or archive trouble, with the memory retries first")
    func unarc() {
        let d = InstallLog.diagnose(exitCode: 0, log: fixture("unarc-error"))
        #expect(d.kind == .decompression)
        #expect(d.causes == [.memory, .path, .damagedFile])
        #expect(Array(d.fixes.prefix(3)) == [.lessMemory, .fewerThreads, .verifyFiles])
        #expect(d.explanation == .decompressorMemory)
        #expect(d.detail == "An error occurred while unpacking: Unarc.dll returned an error code: -11")
        #expect(!d.succeeded)
    }

    @Test("An ISDone.dll missing part is its own verdict, not a decompression guess")
    func isdone() {
        let d = InstallLog.diagnose(exitCode: 1, log: fixture("isdone-error"))
        #expect(d.kind == .missingPart)
        #expect(d.causes == [.missingPart])
        #expect(d.explanation == .missingPart)
        #expect(d.detail == "ISDone.dll: It is not found any file specified for ISArcExtract")
    }

    @Test("The unpackers' error codes map to what they mean", arguments: [
        (-1, InstallDiagnosis.Explanation.decompressorData),
        (-3, .decompressorData),
        (-2, .decompressorMemory),
        (-12, .decompressorMemory),
        (-6, .decompressorIO),
        (-7, .decompressorIO),
        (-9, .helperFailed),
    ])
    func unarcCodes(code: Int, explanation: InstallDiagnosis.Explanation) {
        let log = "Message box (OK):\n  An error occurred while unpacking: Unarc.dll returned an error code: \(code)\n"
        let d = InstallLog.diagnose(exitCode: 1, log: log)
        #expect(d.kind == .decompression)
        #expect(d.explanation == explanation)
    }

    @Test("A log that ends at the temp dir means the setup died before its first page")
    func diedBeforeWizard() {
        let d = InstallLog.diagnose(exitCode: 1, log: fixture("died-early"))
        #expect(d.kind == .setupFailed)
        #expect(d.explanation == .diedBeforeWizard)
        #expect(d.causes == [.runner])
        #expect(d.detail == #"Created temporary directory: C:\users\user\AppData\Local\Temp\is-IJK6I.tmp"#)
    }

    @Test("When Inno's log says nothing, Wine's own output names what crashed")
    func wineFallback() {
        let d = InstallLog.diagnose(
            exitCode: 1,
            log: "Log opened.\nSetup version: Inno Setup version 5.5.1\nStarting the installation process.\nLog closed.",
            wineLog: "mvk-info: Created VkDevice\n0024:err:seh:setup_exception Unhandled page fault on read access to 0x00000000\n")
        #expect(d.kind == .setupFailed)
        #expect(d.detail?.contains("Unhandled page fault") == true)
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
