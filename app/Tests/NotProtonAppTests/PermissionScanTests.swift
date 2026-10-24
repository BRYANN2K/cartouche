import Foundation
import Testing

@testable import NotProtonApp

// Scans the app's Info.plist and sources for permissions no feature uses,
// and for prompts reached from anywhere but the permissions module.
@Suite("Permission scan")
struct PermissionScanTests {

    static let app = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let sources = app.appending(path: "Sources/NotProtonApp")

    @Test("Info.plist describes only the permissions the catalog uses")
    func usageDescriptions() throws {
        let data = try Data(contentsOf: Self.app.appending(path: "Info.plist"))
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let usage = Set(plist.keys.filter { $0.hasSuffix("UsageDescription") })

        #expect(usage == [
            "NSDownloadsFolderUsageDescription",
            "NSRemovableVolumesUsageDescription",
            "NSLocalNetworkUsageDescription",
        ])
        for key in usage {
            #expect((plist[key] as? String)?.hasPrefix("Cartouche ") == true, "\(key)")
        }
        for unused in ["NSCameraUsageDescription", "NSMicrophoneUsageDescription",
                       "NSBluetoothAlwaysUsageDescription", "NSBluetoothPeripheralUsageDescription",
                       "NSScreenCaptureUsageDescription", "NSDesktopFolderUsageDescription",
                       "NSDocumentsFolderUsageDescription", "NSNetworkVolumesUsageDescription",
                       "NSSystemAdministrationUsageDescription", "NSAppleEventsUsageDescription"] {
            #expect(plist[unused] == nil, "\(unused)")
        }
    }

    @Test("The usage descriptions are translated for every app language")
    func usageTranslated() throws {
        for language in ["en", "it", "zh-Hans"] {
            let path = try #require(Bundle.module.path(forResource: "InfoPlist", ofType: "strings",
                                                       inDirectory: nil, forLocalization: language), "\(language)")
            let table = try #require(NSDictionary(contentsOfFile: path) as? [String: String])
            #expect(Set(table.keys) == ["NSDownloadsFolderUsageDescription", "NSRemovableVolumesUsageDescription",
                                        "NSLocalNetworkUsageDescription"], "\(language)")
        }
    }

    func swiftSources() throws -> [(String, String)] {
        let files = FileManager.default.enumerator(at: Self.sources, includingPropertiesForKeys: nil)
        var found: [(String, String)] = []
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let relative = String(url.path(percentEncoded: false).dropFirst(Self.sources.path(percentEncoded: false).count))
            found.append((relative, try String(contentsOf: url, encoding: .utf8)))
        }
        #expect(found.count > 50)
        return found
    }

    @Test("No camera, microphone, screen recording, Bluetooth or Full Disk Access API in the app")
    func noUnusedPermissionAPIs() throws {
        let forbidden = ["AVCaptureDevice", "import AVFoundation", "CoreBluetooth", "CBCentralManager",
                         "CBPeripheralManager", "ScreenCaptureKit", "SCShareableContent",
                         "CGRequestScreenCaptureAccess", "CGPreflightScreenCaptureAccess",
                         "CGWindowListCreateImage", "Privacy_AllFiles", "Privacy_ScreenCapture",
                         "Privacy_Camera", "Privacy_Microphone", "Privacy_Bluetooth"]
        for (file, text) in try swiftSources() {
            for name in forbidden {
                #expect(!text.contains(name), "\(name) in \(file)")
            }
        }
    }

    @Test("Only the permissions module reaches a macOS prompt")
    func promptsOnlyFromTheModule() throws {
        let prompts = ["requestAuthorization", "IOHIDRequestAccess", "AXIsProcessTrustedWithOptions",
                       "SMAppService", "NWBrowser", "LivePermissionRequester"]
        for (file, text) in try swiftSources() where !file.hasPrefix("/Permissions/") && !file.hasPrefix("Permissions/") {
            for name in prompts {
                #expect(!text.contains(name), "\(name) in \(file)")
            }
        }
    }
}
