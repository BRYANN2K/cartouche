import Foundation
import Testing

@testable import NotProtonApp

@Suite("D3DMetal naming, newer versions and the DXMT/DXVK fallback")
struct GraphicsFallbackTests {

    @Test("The shipped manifest names the latest D3DMetal; one without it still reads")
    func latestInManifest() throws {
        #expect(try BackendManifest.bundled().d3dmetal?.version == "4.0b3")
        let json = #"{"format": 1, "revision": 1, "backends": []}"#
        let older = try JSONDecoder().decode(BackendManifest.self, from: Data(json.utf8))
        #expect(older.d3dmetal == nil)
    }

    @Test("A beta sorts before its release and numbers compare as numbers")
    func ordering() {
        #expect(PortingToolkitSource.isOlder("3.0", than: "4.0b3"))
        #expect(PortingToolkitSource.isOlder("4.0b3", than: "4.0"))
        #expect(PortingToolkitSource.isOlder("4.0b2", than: "4.0b3"))
        #expect(PortingToolkitSource.isOlder("4.0", than: "4.10b1"))
        #expect(!PortingToolkitSource.isOlder("4.0", than: "4.0b3"))
        #expect(!PortingToolkitSource.isOlder("4.0b3", than: "4.0b3"))
    }

    @Test("A newer D3DMetal is named only when the newest copy on this Mac is older")
    func newer() {
        #expect(PortingToolkitSource.newer(than: ["3.0"], latest: "4.0b3") == "4.0b3")
        #expect(PortingToolkitSource.newer(than: ["3.0", "4.0b3"], latest: "4.0b3") == nil)
        #expect(PortingToolkitSource.newer(than: ["4.0"], latest: "4.0b3") == nil)
        #expect(PortingToolkitSource.newer(than: [], latest: "4.0b3") == nil)
        #expect(PortingToolkitSource.newer(than: ["3.0"], latest: nil) == nil)
    }

    @Test("Apple's download page is searched for the evaluation environment, not the developer toolkit")
    func naming() {
        #expect(PortingToolkitSource.imageName == "Evaluation environment for Windows games")
        #expect(PortingToolkitSource.howToGetIt.host() == "developer.apple.com")
        #expect(PortingToolkitSource.howToGetIt.query()?.contains("Evaluation%20environment") == true)
    }

    @Test("Only the pinned backends not yet installed are fetched with Cartouche Wine")
    @MainActor
    func missing() throws {
        let manifest = try BackendManifest.bundled()
        #expect(BackendAutoInstall.missing(in: manifest, installed: []).map(\.backend) == [.dxmt, .dxvk])
        #expect(BackendAutoInstall.missing(in: manifest, installed: [.dxmt]).map(\.backend) == [.dxvk])
        #expect(BackendAutoInstall.missing(in: manifest, installed: [.dxmt, .dxvk]).isEmpty)
    }

    @Test("Once DXMT is in, Cartouche Wine under Rosetta picks it before wined3d")
    func fallbackOrder() {
        let runner = GameSetupTests.wine("cartouche-wine-1")
        var availability = BackendAvailability()
        availability.crossOverWine = [runner.id]
        #expect(BackendSupport.backends(for: runner, translation: .rosetta, availability: availability) == [.wined3d])
        availability.installed = [.dxmt, .dxvk]
        #expect(BackendSupport.backends(for: runner, translation: .rosetta, availability: availability) == [.dxmt, .dxvk, .wined3d])
    }
}

@Suite("A toolkit image already open in Finder")
struct AttachedImageTests {

    static func info(_ path: String, mount: String?) -> Data {
        var entity: [String: Any] = ["dev-entry": "/dev/disk9s1"]
        if let mount { entity["mount-point"] = mount }
        let plist: [String: Any] = ["images": [["image-path": path, "system-entities": [["dev-entry": "/dev/disk9"], entity]]]]
        return try! PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    @Test("Its Finder volume is reused instead of a second attach that fails with Resource busy")
    func reused() {
        let dmg = URL(filePath: "/Users/someone/Downloads/Evaluation_environment_for_Windows_games_3.0.dmg")
        let found = DiskImageMounter.mountPoint(of: dmg, info: Self.info(dmg.path(percentEncoded: false), mount: "/Volumes/Evaluation environment for Windows games"))
        #expect(found?.path(percentEncoded: false).hasPrefix("/Volumes/Evaluation environment for Windows games") == true)
    }

    @Test("Another image, or one attached without a volume, is not taken for it")
    func notReused() {
        let dmg = URL(filePath: "/Users/someone/Downloads/a.dmg")
        #expect(DiskImageMounter.mountPoint(of: dmg, info: Self.info("/Users/someone/Downloads/b.dmg", mount: "/Volumes/B")) == nil)
        #expect(DiskImageMounter.mountPoint(of: dmg, info: Self.info(dmg.path(percentEncoded: false), mount: nil)) == nil)
        #expect(DiskImageMounter.mountPoint(of: dmg, info: Data("garbage".utf8)) == nil)
    }
}
