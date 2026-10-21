import Foundation

struct AdvancedGameOptions: Codable, Equatable, Sendable {
    var dlss = false
    var spatial = false
    var spatialFactor = 2.0
    var advertiseAVX = false
    var msync = false
    var highResolution = false
}

enum AdvancedOption: CaseIterable, Hashable, Sendable {
    case dlss, spatial, advertiseAVX, msync, highResolution, metalHUD
}

enum AdvancedSupport {
    static func options(runner: Runner?, backend: GraphicsBackend?, translation: GameSetupChoice.Translation,
                        availability: BackendAvailability, macOSMajor: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
        -> Set<AdvancedOption> {
        guard let runner, backend != nil else { return [] }
        let crossOver = availability.crossOverWine.contains(runner.id) || (runner.kind == .crossOver
            && runner.version.compare("26.3", options: .numeric) != .orderedAscending)
        var options: Set<AdvancedOption> = []
        if crossOver {
            options.formUnion([.msync, .highResolution])
            if translation == .rosetta && macOSMajor >= 15 { options.insert(.advertiseAVX) }
            if backend == .dxmt && translation == .rosetta {
                options.insert(.spatial)
                if availability.dxmtNVExtensionRunners.contains(runner.id) { options.insert(.dlss) }
            }
        }
        if backend == .d3dmetal || backend == .dxmt { options.insert(.metalHUD) }
        return options
    }

    static func environment(_ options: AdvancedGameOptions?, supported: Set<AdvancedOption>,
                            existing: [String: String]) -> [String: String] {
        guard let options else { return existing }
        var env = existing
        if supported.contains(.dlss) { env["DXMT_ENABLE_NVEXT"] = options.dlss ? "1" : "0" }
        if supported.contains(.spatial) {
            env["DXMT_METALFX_SPATIAL_SWAPCHAIN"] = options.spatial ? "1" : "0"
            if options.spatial {
                let factor = options.spatialFactor.isFinite ? min(2, max(1, options.spatialFactor)) : 2
                let key = "d3d11.metalSpatialUpscaleFactor"
                let config = (env["DXMT_CONFIG"] ?? "").split(separator: ";")
                    .filter { $0.split(separator: "=", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces) != key }
                env["DXMT_CONFIG"] = (config.map(String.init) + ["\(key)=\(factor)"]).joined(separator: ";") + ";"
            }
        }
        if supported.contains(.advertiseAVX) { env["ROSETTA_ADVERTISE_AVX"] = options.advertiseAVX ? "1" : "0" }
        if supported.contains(.msync) { env["WINEMSYNC"] = options.msync ? "1" : "0" }
        if supported.contains(.highResolution) { env["CARTOUCHE_RETINA"] = options.highResolution ? "1" : "0" }
        return env
    }

    // Only look in the active backend's Wine DLL search path, never in a runner's source installation.
    static func nvExtensions(runner: Runner, runners: URL, backends: URL) -> URL? {
        let folder: URL
        if runner.kind == .crossOver {
            folder = SupportPaths.clonedRoot(forBuild: runner.id, runners: runners).appending(path: "lib/wine/x86_64-windows")
        } else {
            guard BackendInstaller.receipt(for: .dxmt, in: backends) != nil else { return nil }
            folder = BackendInstaller.folder(for: .dxmt, in: backends).appending(path: "x86_64-windows")
        }
        return ["nvapi64.dll", "nvngx.dll"].allSatisfy {
            FileManager.default.fileExists(atPath: folder.appending(path: $0).path(percentEncoded: false))
        } ? folder : nil
    }
}
