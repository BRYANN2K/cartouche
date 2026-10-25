// A dropped Game Porting Toolkit image is mounted read-only, the D3DMetal
// pieces the runner import uses are copied through PortingToolkitSource, and
// the image is detached again. Cartouche never ships or downloads the toolkit.

import Foundation

struct DiskImageMounter: Sendable {
    // Mounts the image and returns its mount point
    var mount: @Sendable (URL) async throws -> URL
    var unmount: @Sendable (URL) async -> Void

    static var hdiutil: DiskImageMounter {
        DiskImageMounter(
            mount: { dmg in
                try await Task.detached {
                    // An image the user already opened in Finder cannot be attached a second time: "Resource busy"
                    if let info = try? Shell.run("/usr/bin/hdiutil", ["info", "-plist"]), info.succeeded,
                       let mounted = mountPoint(of: dmg, info: Data(info.stdout.utf8)) {
                        return mounted
                    }
                    let point = URL.temporaryDirectory
                        .appending(path: "\(ownPrefix)\(UUID().uuidString)", directoryHint: .isDirectory)
                    try FileManager.default.createDirectory(at: point, withIntermediateDirectories: true)
                    do {
                        _ = try Shell.check("/usr/bin/hdiutil", [
                            "attach", dmg.path(percentEncoded: false),
                            "-readonly", "-nobrowse", "-noverify",
                            "-mountpoint", point.path(percentEncoded: false)])
                    } catch {
                        try? FileManager.default.removeItem(at: point)
                        throw error
                    }
                    return point
                }.value
            },
            unmount: { point in
                await Task.detached {
                    // A volume Cartouche did not mount stays as the user left it
                    guard point.lastPathComponent.hasPrefix(ownPrefix) else { return }
                    if let result = try? Shell.run("/usr/bin/hdiutil",
                                       ["detach", point.path(percentEncoded: false), "-quiet"]), result.succeeded {
                        try? FileManager.default.removeItem(at: point)
                    }
                }.value
            })
    }

    static let ownPrefix = "cartouche-gptk-"

    // The mount point of the image when hdiutil already has it attached
    static func mountPoint(of dmg: URL, info: Data) -> URL? {
        guard let plist = try? PropertyListSerialization.propertyList(from: info, format: nil) as? [String: Any],
              let images = plist["images"] as? [[String: Any]]
        else { return nil }
        let wanted = dmg.resolvingSymlinksInPath().standardizedFileURL.path(percentEncoded: false)
        for image in images {
            guard let path = image["image-path"] as? String,
                  URL(filePath: path).resolvingSymlinksInPath().standardizedFileURL.path(percentEncoded: false) == wanted
            else { continue }
            let entities = image["system-entities"] as? [[String: Any]] ?? []
            if let point = entities.compactMap({ $0["mount-point"] as? String }).first {
                return URL(filePath: point, directoryHint: .isDirectory)
            }
        }
        return nil
    }
}

enum PortingToolkitDMG {

    static let step = String(localized: "Import the Game Porting Toolkit")

    // Returns the toolkit version that landed in the runners folder. The image
    // is always detached again, success or failure.
    @discardableResult
    static func importImage(
        _ dmg: URL,
        runners: URL = SupportPaths.runners,
        mounter: DiskImageMounter = .hdiutil
    ) async throws -> String {
        let point = try await mounter.mount(dmg)
        let version: String
        do {
            guard let lib = PortingToolkitSource.lib(in: point),
                  let found = PortingToolkitSource.version(ofLib: lib)
            else {
                throw StepFailure(
                    step: step,
                    detail: String(localized: "This image holds no D3DMetal. Use Apple’s “\(PortingToolkitSource.imageName)” image, not “Game Porting Toolkit”."))
            }
            let install = PortingToolkitInstall(lib: lib, version: found, origin: dmg, mountedImage: true)
            try PortingToolkitSource.copy(install, runners: runners)
            version = found
        } catch {
            await mounter.unmount(point)
            throw error
        }
        await mounter.unmount(point)
        return version
    }
}
