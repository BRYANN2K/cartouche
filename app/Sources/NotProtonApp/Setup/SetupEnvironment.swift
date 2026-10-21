// The backend is applied as the Steam run script does (compat_run.sh): CrossOver gets CX_GRAPHICS_BACKEND and uses
// its own copy; another Wine gets Cartouche's pinned DXMT or DXVK first in WINEDLLPATH. The prefix is never copied.

import Foundation
import InstallerKit

enum SetupEnvironment {

    // The minimal environment every game, installer and store client starts from:
    // nothing of the calling process leaks through.
    static let base: [String: String] = [
        "HOME": SupportPaths.home.path(percentEncoded: false),
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "LANG": "en_US.UTF-8",
    ]

    // Only the names GameSetupResolver forwards are kept.
    static func make(
        wine: WineRunner, prefix: URL, backend: GraphicsBackend?,
        environment: [String: String] = [:],
        backends: URL = BackendInstaller.folder, runners: URL = SupportPaths.runners,
        base: [String: String]
    ) -> [String: String] {
        var env = WineInstall.environment(runner: wine, prefix: prefix, inputs: nil, base: base)
        applyBackend(&env, backend: backend, wine: wine, backends: backends, runners: runners)
        for (name, value) in environment where GameSetupResolver.isAllowed(name: name, value: value) {
            env[name] = value
        }
        if env["DXMT_ENABLE_NVEXT"] == "1" {
            env["WINEDLLOVERRIDES"] = (env["WINEDLLOVERRIDES"].map { $0 + ";" } ?? "") + "nvapi64=n;nvngx=b"
        }
        return env
    }

    // The backend part: CX_GRAPHICS_BACKEND always, and for a non-CrossOver Wine the user's libd3dshared or the pinned DXMT or DXVK DLLs ahead of WINEDLLPATH.
    static func applyBackend(
        _ env: inout [String: String], backend: GraphicsBackend?, wine: WineRunner,
        backends: URL, runners: URL = SupportPaths.runners
    ) {
        guard let backend else { return }
        env["CX_GRAPHICS_BACKEND"] = backend.rawValue
        let crossOver = FileManager.default.fileExists(atPath: wine.root.appending(path: "share/crossover").path(percentEncoded: false))
        guard !crossOver else { return }
        // A Wine built from CodeWeavers' source loads D3DMetal through this: the build's own
        // apple_gptk when it carries one, else the user's Game Porting Toolkit copy.
        if backend == .d3dmetal {
            let own = wine.root.appending(path: "lib64/apple_gptk/external/libd3dshared.dylib")
            let shared = FileManager.default.fileExists(atPath: own.path(percentEncoded: false)) ? own
                : PortingToolkitSource.libd3dshared(runners: runners)
            if let shared { env["CX_APPLEGPTK_LIBD3DSHARED_PATH"] = shared.path(percentEncoded: false) }
        }
        if let dlls = dlls(backend, backends: backends) {
            env["WINEDLLPATH"] = ([dlls.path] + [env["WINEDLLPATH"]])
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ":")
            env["WINEDLLOVERRIDES"] = ([env["WINEDLLOVERRIDES"]] + [dlls.overrides])
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ";")
        }
    }

    // DXMT or DXVK from backends/, only once their files are in place
    static func dlls(_ backend: GraphicsBackend, backends: URL) -> (path: String, overrides: String)? {
        guard backend == .dxmt || backend == .dxvk, BackendInstaller.receipt(for: backend, in: backends) != nil else { return nil }
        let root = BackendInstaller.folder(for: backend, in: backends)
        let folders = BackendInstaller.folders.map { root.appending(path: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
        guard !folders.isEmpty else { return nil }
        let overrides = backend == .dxmt ? "d3d11,dxgi,d3d10core=b" : "d3d9,d3d10core,d3d11,dxgi=b"
        return (folders.map { $0.path(percentEncoded: false) }.joined(separator: ":"), overrides)
    }

    static func prepareNVExtensions(wine: WineRunner, prefix: URL, environment: [String: String]) throws {
        guard environment["DXMT_ENABLE_NVEXT"] == "1",
              let path = environment["WINEDLLPATH"] else { return }
        for name in ["nvapi64.dll", "nvngx.dll"] {
            guard let source = path.split(separator: ":").map({ URL(filePath: String($0)).appending(path: name) })
                .first(where: { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }) else { continue }
            let target = prefix.appending(path: "drive_c/windows/system32/\(name)")
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.copyItem(at: source, to: target)
        }
    }

    // DXMT's guide puts winemetal.dll in the prefix as well
    static func prepare(_ backend: GraphicsBackend?, prefix: URL, backends: URL = BackendInstaller.folder) {
        guard backend == .dxmt, BackendInstaller.receipt(for: .dxmt, in: backends) != nil else { return }
        let source = BackendInstaller.folder(for: .dxmt, in: backends).appending(path: "x86_64-windows/winemetal.dll")
        let target = prefix.appending(path: "drive_c/windows/system32/winemetal.dll")
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path(percentEncoded: false)),
              fm.fileExists(atPath: target.deletingLastPathComponent().path(percentEncoded: false)) else { return }
        try? fm.removeItem(at: target)
        try? fm.copyItem(at: source, to: target)
    }
}
