// The Wine environment a resolved setup produces, shared by every game Cartouche
// starts itself: store games (StorePlay) and games installed from a Windows
// installer (GameLauncher). The backend is applied as the Steam run script does
// (compat_run.sh): CrossOver gets CX_GRAPHICS_BACKEND and uses its own copy;
// another Wine gets Cartouche's pinned DXMT or DXVK first in WINEDLLPATH, as
// builtin DLLs. The prefix is never copied: one game, one prefix, every setup.

import Foundation
import InstallerKit

enum SetupEnvironment {

    // Wine's own variables plus the backend and the game's extra variables.
    // Only the names GameSetupResolver forwards are kept.
    static func make(
        wine: WineRunner, prefix: URL, backend: GraphicsBackend?,
        environment: [String: String] = [:],
        backends: URL = BackendInstaller.folder, base: [String: String]
    ) -> [String: String] {
        var env = WineInstall.environment(runner: wine, prefix: prefix, inputs: nil, base: base)
        applyBackend(&env, backend: backend, wine: wine, backends: backends)
        for (name, value) in environment where GameSetupResolver.isAllowed(name: name, value: value) {
            env[name] = value
        }
        return env
    }

    // The backend part: CX_GRAPHICS_BACKEND always, and for a non-CrossOver Wine
    // the pinned DLLs ahead of WINEDLLPATH with their builtin overrides.
    static func applyBackend(_ env: inout [String: String], backend: GraphicsBackend?, wine: WineRunner, backends: URL) {
        guard let backend else { return }
        env["CX_GRAPHICS_BACKEND"] = backend.rawValue
        let crossOver = FileManager.default.fileExists(atPath: wine.root.appending(path: "share/crossover").path(percentEncoded: false))
        if !crossOver, let dlls = dlls(backend, backends: backends) {
            env["WINEDLLPATH"] = dlls.path + ":" + (env["WINEDLLPATH"] ?? "")
            env["WINEDLLOVERRIDES"] = (env["WINEDLLOVERRIDES"].map { $0 + ";" } ?? "") + dlls.overrides
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
