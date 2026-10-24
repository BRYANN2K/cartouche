import Foundation
import RetroArchKit
import Testing

@testable import NotProtonApp

@Suite("Standalone emulator installation")
@MainActor
struct EmulatorInstallerTests {
    @Test("A pinned archive installs into Applications; hash mismatches never publish an app", arguments: [true, false])
    func archive(validHash: Bool) async throws {
        let work = try scratchDirectory("emulator-install")
        defer { try? FileManager.default.removeItem(at: work) }
        let app = try FakeEmulatorApp.install("eden", bundleID: "com.yuzu-emu.yuzu", version: "test", in: work.appending(path: "source"))
        let zip = work.appending(path: "eden.zip")
        try await Task.detached {
            try Shell.check("/usr/bin/ditto", ["-c", "-k", "--keepParent", app.path, zip.path])
        }.value
        let bytes = try Data(contentsOf: zip)
        let web = StubWeb()
        web.put("/eden.zip", bytes)
        let spec = EmulatorManifest.Download(id: "eden", version: "test", url: web.base.appending(path: "eden.zip"),
            sha256: validHash ? Digest.sha256(of: bytes) : String(repeating: "0", count: 64), archive: "zip")
        var installer = EmulatorInstaller(applications: work.appending(path: "Applications"), downloads: work.appending(path: "downloads"))
        installer.manifest = { EmulatorManifest(format: 1, downloads: [spec]) }
        installer.session = web.session
        installer.verify = { _ in }
        let emulator = try #require(EmulatorCatalog.emulator("eden"))
        do {
            let installed = try await installer.install(emulator)
            #expect(validHash)
            #expect(installed.app == installer.applications.appending(path: "eden.app"))
            #expect(installed.id == "eden")
            #expect(FileManager.default.isExecutableFile(atPath: installed.executable.path))
        } catch {
            #expect(!validHash, "Unexpected installation failure: \(error)")
            #expect(!FileManager.default.fileExists(atPath: installer.applications.appending(path: "eden.app").path))
        }
    }

    @Test("The bundled download manifest validates")
    func manifest() throws {
        let manifest = try EmulatorManifest.bundled()
        #expect(manifest.problems().isEmpty)
        #expect(manifest.downloads.contains { $0.id == "eden" })
    }
}
