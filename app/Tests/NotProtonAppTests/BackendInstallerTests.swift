import CryptoKit
import Foundation
import Testing

@testable import NotProtonApp

// Fixture archives laid out like the DXMT and DXVK release tarballs, served from file
// URLs in a scratch folder. No network, no real backends folder, no prefix.
@Suite("Graphics backend downloads")
final class BackendInstallerTests {

    let work: URL
    let backends: URL
    let downloads: URL

    init() throws {
        work = try scratchDirectory("backends")
        backends = work.appending(path: "backends")
        downloads = work.appending(path: "downloads")
    }

    deinit { try? FileManager.default.removeItem(at: work) }

    // dxmt-v0.80/x86_64-windows/... as the builtin tarball holds it; DXVK's older layout uses x64/x32
    static func archive(in work: URL, _ name: String, top: String, files: [String: String]) throws -> URL {
        let tree = work.appending(path: "tree-\(UUID().uuidString)")
        let fm = FileManager.default
        for (path, text) in files {
            let file = tree.appending(path: top).appending(path: path)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file)
        }
        let host = work.appending(path: "host-\(UUID().uuidString)")
        try fm.createDirectory(at: host, withIntermediateDirectories: true)
        let out = host.appending(path: name)
        try Shell.check("/usr/bin/tar", ["-czf", out.path(percentEncoded: false), "-C", tree.path(percentEncoded: false), top])
        return out
    }

    func archive(_ name: String, top: String, files: [String: String]) throws -> URL {
        try Self.archive(in: work, name, top: top, files: files)
    }

    static let dxmtFiles = [
        "x86_64-windows/d3d11.dll": "MZ dxmt d3d11", "x86_64-windows/dxgi.dll": "MZ dxmt dxgi",
        "x86_64-windows/winemetal.dll": "MZ winemetal", "x86_64-unix/winemetal.so": "winemetal unix",
        "i386-windows/d3d11.dll": "MZ dxmt d3d11 32",
    ]

    func pin(_ backend: GraphicsBackend, for archive: URL, sha256: String? = nil, size: Int64? = nil) throws -> BackendManifest.Pin {
        let bytes = try FileManager.default.attributesOfItem(atPath: archive.path(percentEncoded: false))[.size] as! Int64
        let shipped = try #require(BackendManifest.bundled().pin(backend))
        return BackendManifest.Pin(
            backend: backend, name: shipped.name, version: shipped.version, license: shipped.license, url: archive,
            size: size ?? bytes, sha256: try sha256 ?? Digest.sha256(of: archive), files: shipped.files)
    }

    @Test("The shipped manifest pins DXMT v0.80 and DXVK-macOS from GitHub by size and SHA-256, and nothing else")
    func shipped() throws {
        let manifest = try BackendManifest.bundled()
        #expect(manifest.backends.map(\.backend) == [.dxmt, .dxvk])
        let dxmt = try #require(manifest.pin(.dxmt))
        #expect(dxmt.url.absoluteString == "https://github.com/3Shain/dxmt/releases/download/v0.80/dxmt-v0.80-builtin.tar.gz")
        #expect(dxmt.size == 18_681_669)
        #expect(dxmt.sha256 == "8f260e36b5739e68f3bad613381441385c4dc7b85b78ba8de653d5a6a264529d")
        #expect(dxmt.license == "MIT")
        let dxvk = try #require(manifest.pin(.dxvk))
        #expect(dxvk.url.host() == "github.com" && dxvk.url.path().hasPrefix("/Gcenx/DXVK-macOS/releases/download/"))
        #expect(dxvk.sha256 == "810b1e5caf8ce975b784fae866a130ad23fa0ea233b0e5609cbc4a45f3ef6f00")
        #expect(dxvk.license == "Zlib")
        #expect(manifest.pin(.d3dmetal) == nil && manifest.pin(.wined3d) == nil)
    }

    @Test("A manifest that lists D3DMetal, a bad hash, another host or a path outside the backend folders is refused")
    func refusals() throws {
        let good = try String(contentsOf: IdentityTests.repoRoot.appending(path: "app/Sources/NotProtonApp/Resources/backends.json"), encoding: .utf8)
        for (bad, why) in [
            (good.replacingOccurrences(of: "\"backend\": \"dxmt\"", with: "\"backend\": \"d3dmetal\""), "d3dmetal is not downloadable"),
            (good.replacingOccurrences(of: "8f260e36b5", with: "8F260E36B5"), "is not a SHA-256"),
            (good.replacingOccurrences(of: "https://github.com/3Shain", with: "https://example.com/3Shain"), "not an https URL"),
            (good.replacingOccurrences(of: "\"x86_64-unix/winemetal.so\"", with: "\"../winemetal.so\""), "is outside"),
            (good.replacingOccurrences(of: "\"backend\": \"dxvk\"", with: "\"backend\": \"dxmt\""), "listed twice"),
        ] {
            #expect(bad != good)
            do {
                _ = try BackendManifest.read(Data(bad.utf8))
                Issue.record("accepted: \(why)")
            } catch let invalid as BackendManifest.Invalid {
                #expect(invalid.description.contains(why), "\(invalid)")
            }
        }
    }

    @Test("DXMT is downloaded, matches its SHA-256, and only then unpacks into backends/dxmt with a receipt")
    func installDXMT() async throws {
        let pin = try pin(.dxmt, for: archive("dxmt-v0.80-builtin.tar.gz", top: "dxmt-v0.80", files: Self.dxmtFiles))
        let receipt = try await BackendInstaller.install(pin, backends: backends, downloads: downloads)

        #expect(receipt.archiveSHA256 == pin.sha256)
        #expect(receipt.version == "0.80")
        #expect(Set(receipt.files.keys) == Set(Self.dxmtFiles.keys))
        let folder = BackendInstaller.folder(for: .dxmt, in: backends)
        #expect(try String(contentsOf: folder.appending(path: "x86_64-unix/winemetal.so"), encoding: .utf8) == "winemetal unix")
        #expect(BackendInstaller.installed(in: backends).map(\.backend) == [.dxmt])
        #expect(receipt.files.allSatisfy { path, hash in
            Digest.sha256IfPresent(folder.appending(path: path)) == hash
        })
        // The archive is not kept, and nothing half done is left beside the backend
        #expect(try FileManager.default.contentsOfDirectory(atPath: downloads.path(percentEncoded: false)).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: backends.path(percentEncoded: false)) == ["dxmt"])
    }

    @Test("DXVK's x64 and x32 folders land where the run script reads them")
    func installDXVKOldLayout() async throws {
        let files = ["x64/d3d11.dll": "MZ dxvk 64", "x64/d3d10core.dll": "MZ d3d10core 64", "x32/d3d11.dll": "MZ dxvk 32"]
        let pin = try pin(.dxvk, for: archive("dxvk.tar.gz", top: "dxvk-macOS-async", files: files))
        let receipt = try await BackendInstaller.install(pin, backends: backends, downloads: downloads)
        #expect(Set(receipt.files.keys) == ["x86_64-windows/d3d11.dll", "x86_64-windows/d3d10core.dll", "i386-windows/d3d11.dll"])
    }

    @Test("A DXMT download whose SHA-256 differs is deleted and nothing is unpacked")
    func tampered() async throws {
        let real = try archive("dxmt-v0.80-builtin.tar.gz", top: "dxmt-v0.80", files: Self.dxmtFiles)
        let pinned = try pin(.dxmt, for: real)
        var changed = Self.dxmtFiles
        changed["x86_64-windows/d3d11.dll"] = "MZ something else"
        let tampered = try archive("dxmt-v0.80-builtin.tar.gz", top: "dxmt-v0.80", files: changed)
        let served = BackendManifest.Pin(backend: .dxmt, name: pinned.name, version: pinned.version, license: pinned.license,
                                         url: tampered, size: pinned.size, sha256: pinned.sha256, files: pinned.files)
        do {
            try await BackendInstaller.install(served, backends: backends, downloads: downloads)
            Issue.record("a tampered DXMT was installed")
        } catch let failure as StepFailure {
            #expect(failure.detail == "Something is wrong with the downloaded files. Please check for a Cartouche update.")
        }
        let fm = FileManager.default
        #expect(((try? fm.contentsOfDirectory(atPath: downloads.path(percentEncoded: false))) ?? []).isEmpty)
        #expect(((try? fm.contentsOfDirectory(atPath: backends.path(percentEncoded: false))) ?? []).isEmpty)
        #expect(BackendInstaller.installed(in: backends).isEmpty)
    }

    @Test("An archive swapped in the downloads folder after the check is deleted, never unpacked")
    func swappedBeforeUnpack() throws {
        let real = try archive("dxmt-v0.80-builtin.tar.gz", top: "dxmt-v0.80", files: Self.dxmtFiles)
        let pin = try pin(.dxmt, for: real)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let local = downloads.appending(path: pin.archiveName)
        try Data("not the pinned archive".utf8).write(to: local)
        #expect(throws: StepFailure.self) { try BackendInstaller.unpack(local, pin: pin, backends: backends) }
        #expect(!FileManager.default.fileExists(atPath: local.path(percentEncoded: false)))
        #expect(BackendInstaller.installed(in: backends).isEmpty)
    }

    @Test("An archive without the pinned files is refused and leaves nothing")
    func missingFiles() async throws {
        let pin = try pin(.dxmt, for: archive("dxmt.tar.gz", top: "dxmt", files: ["x86_64-windows/d3d11.dll": "MZ"]))
        await #expect(throws: StepFailure.self) { try await BackendInstaller.install(pin, backends: self.backends, downloads: self.downloads) }
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: backends.path(percentEncoded: false))) ?? []).isEmpty)
    }

    @Test("Installing again over a changed file puts the receipt's file back")
    func damage() async throws {
        let pin = try pin(.dxmt, for: archive("dxmt-v0.80-builtin.tar.gz", top: "dxmt-v0.80", files: Self.dxmtFiles))
        let receipt = try await BackendInstaller.install(pin, backends: backends, downloads: downloads)
        let dxgi = BackendInstaller.folder(for: .dxmt, in: backends).appending(path: "x86_64-windows/dxgi.dll")
        try Data("MZ changed".utf8).write(to: dxgi)
        #expect(Digest.sha256IfPresent(dxgi) != receipt.files["x86_64-windows/dxgi.dll"])
        try await BackendInstaller.install(pin, backends: backends, downloads: downloads)
        #expect(Digest.sha256IfPresent(dxgi) == receipt.files["x86_64-windows/dxgi.dll"])
    }

    // The settings screen awaits install on the main actor: tar's wait must not run
    // there. In a debug build Shell traps the moment it does, so a pass proves it.
    @MainActor
    @Test("Awaited on the main actor, the unpack's waits stay off it")
    func installNeverWaitsOnMain() async throws {
        let work = work
        let archive = try await offMain {
            try BackendInstallerTests.archive(in: work, "dxmt-v0.80-builtin.tar.gz", top: "dxmt-v0.80", files: BackendInstallerTests.dxmtFiles)
        }
        let receipt = try await BackendInstaller.install(
            pin(.dxmt, for: archive), backends: backends, downloads: downloads)
        #expect(receipt.backend == .dxmt)
        #expect(BackendInstaller.installed(in: backends).map(\.backend) == [.dxmt])
    }

    @Test("An update while a game uses the backend is refused with the usual message and keeps the old files")
    func refusedWhileInUse() async throws {
        let pin = try pin(.dxmt, for: archive("dxmt-v0.80-builtin.tar.gz", top: "dxmt-v0.80", files: Self.dxmtFiles))
        let receipt = try await BackendInstaller.install(pin, backends: backends, downloads: downloads)
        let target = BackendInstaller.folder(for: .dxmt, in: backends)
        let dxgi = target.appending(path: "x86_64-windows/dxgi.dll")
        try Data("MZ changed".utf8).write(to: dxgi)
        do {
            try await BackendInstaller.install(pin, backends: backends, downloads: downloads, inUse: { $0 == target })
            Issue.record("installed over a backend in use")
        } catch let failure as StepFailure {
            #expect(failure.detail == "A game is using \(pin.name). Quit the game first.")
        }
        #expect(Digest.sha256IfPresent(dxgi) != receipt.files["x86_64-windows/dxgi.dll"], "the files in use are untouched")
    }

    @Test("A process holding one of the backend's files open makes it in use; none, or no receipt, leaves it free")
    func inUseProbe() async throws {
        let pin = try pin(.dxmt, for: archive("dxmt-v0.80-builtin.tar.gz", top: "dxmt-v0.80", files: Self.dxmtFiles))
        try await BackendInstaller.install(pin, backends: backends, downloads: downloads)
        let target = BackendInstaller.folder(for: .dxmt, in: backends)
        let other = BackendInstaller.folder(for: .dxvk, in: backends)
        #expect(try await offMain { BackendInstaller.isInUse(target) } == false)
        #expect(try await offMain { BackendInstaller.isInUse(other) } == false)
        let held = try FileHandle(forReadingFrom: target.appending(path: "x86_64-unix/winemetal.so"))
        #expect(try await offMain { BackendInstaller.isInUse(target) })
        try held.close()
        #expect(try await offMain { BackendInstaller.isInUse(target) } == false)
        #expect(try await offMain { BackendInstaller.isInUse(target, lsof: "/nonexistent/lsof") })
    }

    @Test("An install that cannot write its folder leaves the old one working")
    func keepsOldInstall() async throws {
        let pin = try pin(.dxmt, for: archive("dxmt-v0.80-builtin.tar.gz", top: "dxmt-v0.80", files: Self.dxmtFiles))
        try await BackendInstaller.install(pin, backends: backends, downloads: downloads)
        let dxgi = BackendInstaller.folder(for: .dxmt, in: backends).appending(path: "x86_64-windows/dxgi.dll")
        let before = try Digest.sha256(of: dxgi)

        let restore = { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: self.backends.path(percentEncoded: false)) }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: backends.path(percentEncoded: false))
        defer { restore() }
        await #expect(throws: (any Error).self) {
            try await BackendInstaller.install(pin, backends: self.backends, downloads: self.downloads)
        }
        restore()
        #expect(try Digest.sha256(of: dxgi) == before, "the previous install is untouched")
    }
}

@Suite("Graphics backend manifest refresh")
struct BackendManifestRefreshTests {

    private static func signed(_ manifest: Data, key: Curve25519.Signing.PrivateKey) throws
        -> @Sendable (URL) async throws -> (Data, Int) {
        let signature = try key.signature(for: manifest)
        let sig = Data(signature.base64EncodedString().utf8)
        return { url in url.pathExtension == "sig" ? (sig, 200) : (manifest, 200) }
    }

    private static func bundledText() throws -> String {
        let file = IdentityTests.repoRoot.appending(path: "app/Sources/NotProtonApp/Resources/backends.json")
        return try String(contentsOf: file, encoding: .utf8)
    }

    @Test("The compat-data feed names backends.json beside compat.json.gz")
    func feed() throws {
        let compat = try #require(URL(string: "https://github.com/BRYANN2K/cartouche/releases/download/compat-data/compat.json.gz"))
        #expect(BackendManifest.feed(fromCompat: compat)?.absoluteString
            == "https://github.com/BRYANN2K/cartouche/releases/download/compat-data/backends.json")
    }

    @Test("A higher revision with a changed pin is kept; a bad signature leaves the cache alone")
    func refreshKeepsChangedPin() async throws {
        let work = try scratchDirectory("backend-manifest")
        defer { try? FileManager.default.removeItem(at: work) }
        let cache = work.appending(path: "backends.json")
        let url = try #require(URL(string: "https://github.com/BRYANN2K/cartouche/releases/download/compat-data/backends.json"))
        let shipped = try BackendManifest.bundled()
        var text = try Self.bundledText()
        text = text.replacingOccurrences(of: "\"revision\": 1", with: "\"revision\": 2")
        text = text.replacingOccurrences(of: "\"version\": \"0.80\"", with: "\"version\": \"0.81\"")
        text = text.replacingOccurrences(of: "8f260e36b5739e68", with: "9f260e36b5739e68")
        let newerData = Data(text.utf8)
        let newer = try BackendManifest.read(newerData)
        #expect(BackendManifest.merged(bundled: shipped, refreshed: newer).pin(.dxmt)?.version == "0.81")
        let sameRevision = text.replacingOccurrences(of: "\"revision\": 2", with: "\"revision\": 1")
        #expect(BackendManifest.merged(bundled: shipped, refreshed: try BackendManifest.read(Data(sameRevision.utf8))) == shipped)

        let signing = Curve25519.Signing.PrivateKey()
        let fetch = try Self.signed(newerData, key: signing)
        let updated = await BackendManifest.refresh(from: url, cache: cache, fetch: fetch, key: signing.publicKey)
        #expect(updated == .updated(revision: 2))
        #expect(BackendManifest.current(cache: cache, key: signing.publicKey).pin(.dxmt)?.version == "0.81")

        let again = await BackendManifest.refresh(from: url, cache: cache, fetch: fetch, key: signing.publicKey)
        #expect(again == .unchanged)

        let forged = try Self.signed(newerData, key: Curve25519.Signing.PrivateKey())
        let rejected = await BackendManifest.refresh(from: url, cache: cache, fetch: forged, key: signing.publicKey)
        guard case .rejected = rejected else { Issue.record("\(rejected)"); return }
        #expect(try Data(contentsOf: cache) == newerData)

        let metal = try Self.bundledText().replacingOccurrences(of: "\"backend\": \"dxmt\"", with: "\"backend\": \"d3dmetal\"")
            .replacingOccurrences(of: "\"revision\": 1", with: "\"revision\": 9")
        let refused = try Self.signed(Data(metal.utf8), key: signing)
        let notDownloadable = await BackendManifest.refresh(from: url, cache: cache, fetch: refused, key: signing.publicKey)
        guard case .rejected = notDownloadable else { Issue.record("\(notDownloadable)"); return }
        #expect(try Data(contentsOf: cache) == newerData)

        let missing = await BackendManifest.refresh(from: url, cache: cache, fetch: { _ in (Data(), 404) }, key: signing.publicKey)
        #expect(missing == .unavailable)
        #expect(try Data(contentsOf: cache) == newerData)
    }
}
