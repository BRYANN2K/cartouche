import Foundation

// Without D3DMetal a Cartouche Wine game falls back to wined3d, which Unity and most DirectX 11 games refuse,
// so the pinned DXMT and DXVK come with the runner instead of waiting for a click in Settings.
@MainActor
enum BackendAutoInstall {

    private static var running = false

    static func missing(in manifest: BackendManifest, installed: Set<GraphicsBackend>) -> [BackendManifest.Pin] {
        manifest.backends.filter { !installed.contains($0.backend) }
    }

    static func ensure(
        hasCartoucheWine: Bool, installed: Set<GraphicsBackend>, reload: (@MainActor () async -> Void)?
    ) {
        guard hasCartoucheWine, !running else { return }
        let pins = missing(in: BackendManifest.current(), installed: installed)
        guard !pins.isEmpty else { return }
        running = true
        Task {
            var added = false
            for pin in pins {
                do {
                    try await BackendInstaller.install(pin)
                    added = true
                } catch {
                    AppLog.note("\(pin.id) was not installed with Cartouche Wine: \((error as? StepFailure)?.detail ?? error.localizedDescription)")
                }
            }
            running = false
            if added {
                await BackendDownloadsSection.afterInstall(syncTools: { _ = try CompatToolList.sync() }, reload: reload)
            }
        }
    }
}
