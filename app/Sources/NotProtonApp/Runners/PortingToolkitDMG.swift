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
                    let point = URL.temporaryDirectory
                        .appending(path: "cartouche-gptk-\(UUID().uuidString)", directoryHint: .isDirectory)
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
                    if let result = try? Shell.run("/usr/bin/hdiutil",
                                       ["detach", point.path(percentEncoded: false), "-quiet"]), result.succeeded {
                        try? FileManager.default.removeItem(at: point)
                    }
                }.value
            })
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
                    detail: String(localized: "The image holds no Game Porting Toolkit."))
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
