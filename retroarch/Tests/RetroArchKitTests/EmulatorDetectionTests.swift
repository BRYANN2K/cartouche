import Foundation
import Testing

@testable import RetroArchKit

// Finding the apps in /Applications and ~/Applications. Every app here
// is a fake one made in a scratch folder.
@Suite("Standalone emulator detection")
struct EmulatorDetectionTests {

    @Test func detectionReadsBundleIdentifierAndVersion() throws {
        let work = try scratchFolder("detect")
        defer { try? FileManager.default.removeItem(at: work) }
        let applications = work.appending(path: "Applications", directoryHint: .isDirectory)
        let home = work.appending(path: "home/Applications", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FakeEmulators.app("Dolphin", in: applications, bundleID: "org.dolphin-emu.dolphin", version: "2509")
        // Renamed by the user: the identifier still says what it is
        try FakeEmulators.app("PS2 Emulator", in: home, bundleID: "net.pcsx2.pcsx2", executable: "PCSX2", version: "2.6.3")
        // Only a build number
        try FakeEmulators.app("Ryujinx", in: home, bundleID: "org.ryujinx.Ryujinx", version: nil, build: "1.3.3")
        // Not an emulator, and an emulator with no executable
        try FakeEmulators.app("TextEdit", in: applications, bundleID: "com.apple.TextEdit")
        let broken = try FakeEmulators.app("xemu", in: applications, bundleID: "xemu.app.0")
        try FileManager.default.removeItem(at: broken.appending(path: "Contents/MacOS/xemu"))

        let found = EmulatorDetector(folders: [applications, home.deletingLastPathComponent().appending(path: "Applications")]).installed()
        #expect(found.map(\.id) == ["dolphin", "pcsx2", "ryubing"])
        #expect(found.map(\.title) == ["Dolphin 2509", "PCSX2 2.6.3", "Ryubing 1.3.3"])
        #expect(found[0].app.lastPathComponent == "Dolphin.app")
        #expect(found[0].executable.path.hasSuffix("Dolphin.app/Contents/MacOS/Dolphin"))
        #expect(found[1].executable.lastPathComponent == "PCSX2")
    }

    @Test func detectionLooksOneFolderDeepAndTheFirstFolderWins() throws {
        let work = try scratchFolder("detect-deep")
        defer { try? FileManager.default.removeItem(at: work) }
        let first = work.appending(path: "Applications", directoryHint: .isDirectory)
        let second = work.appending(path: "home/Applications", directoryHint: .isDirectory)
        try FakeEmulators.app("Dolphin", in: first.appending(path: "Emulators"), bundleID: "org.dolphin-emu.dolphin", version: "2509")
        try FakeEmulators.app("Dolphin", in: second, bundleID: "org.dolphin-emu.dolphin", version: "2412")
        let found = EmulatorDetector(folders: [first, second]).installed()
        #expect(found.map(\.title) == ["Dolphin 2509"])
        #expect(found[0].app.deletingLastPathComponent().lastPathComponent == "Emulators")
    }

    @Test func everyCatalogAppIsFoundAsItShips() throws {
        let work = try scratchFolder("detect-all")
        defer { try? FileManager.default.removeItem(at: work) }
        try FakeEmulators.installAll(in: work)
        let found = EmulatorDetector(folders: [work]).installed()
        #expect(found.map(\.id) == EmulatorCatalog.all.map(\.id))
        for installed in found {
            #expect(installed.executable.lastPathComponent == installed.emulator.executableName)
        }
    }

    @Test func noFolderNoEmulator() {
        let found = EmulatorDetector(folders: [URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")]).installed()
        #expect(found.isEmpty)
    }
}
