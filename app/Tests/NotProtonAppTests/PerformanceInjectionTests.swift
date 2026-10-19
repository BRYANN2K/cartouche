import Foundation
import Testing

@testable import NotProtonApp

// The frame counter reaches the support folder with the other components, and the run
// script names the same files and folders the app reads (P8)
@Suite("Frame counter deployment")
struct PerformanceInjectionTests {

    private func payload(_ root: URL, counter: Bool) throws -> InstallPayload.Located {
        let files = FileManager.default
        try files.createDirectory(at: root.appending(path: "signatures/macos.arm64"), withIntermediateDirectories: true)
        try files.createDirectory(at: root.appending(path: "fonts"), withIntermediateDirectories: true)
        for name in [SupportPaths.dylibName, "overlay-shim.dylib", "iconmaker", "appinfo", "run"] {
            try Data(name.utf8).write(to: root.appending(path: name))
        }
        try Data("100\n".utf8).write(to: root.appending(path: "build-time"))
        try Data("{}".utf8).write(to: root.appending(path: "signatures/macos.arm64/1.json"))
        try Data("font".utf8).write(to: root.appending(path: "fonts/arial.ttf"))
        if counter { try Data("counter".utf8).write(to: root.appending(path: SupportPaths.fpsCounterName)) }
        return try InstallPayload.locate(root: root)
    }

    private func files(_ payload: InstallPayload.Located, _ work: URL, counter: URL?) -> [DeploymentContent.File] {
        let support = work.appending(path: "support")
        return DeploymentContent.files(
            payload: payload, bridgePayload: BridgePayload.Located(sources: []), app: work.appending(path: "Steam.app"),
            bridge: support.appending(path: "bridge"), signatures: support.appending(path: "signatures"),
            fonts: support.appending(path: "fonts"), overlayShim: support.appending(path: "overlay-shim.dylib"),
            iconmaker: support.appending(path: "iconmaker"), appinfo: support.appending(path: "appinfo"),
            compatTools: work.appending(path: "compatibilitytools.d"), tools: [], runners: support.appending(path: "runners"),
            fpsCounter: counter)
    }

    @Test("A payload with the counter deploys it beside the overlay shim, without stopping Steam")
    func deployed() throws {
        let work = try scratchDirectory("fps-deploy")
        defer { try? FileManager.default.removeItem(at: work) }
        let located = try payload(work.appending(path: "payload"), counter: true)
        #expect(located.fpsCounter?.lastPathComponent == "fps-counter.dylib")
        let destination = work.appending(path: "support/fps-counter.dylib")
        let file = try #require(files(located, work, counter: destination).first { $0.name == "fps-counter.dylib" })
        #expect(file.destination == destination)
        #expect(!file.needsClientStopped)
        #expect(try !file.matches())
    }

    @Test("A payload staged before P8 still installs, and games then run unmeasured")
    func optional() throws {
        let work = try scratchDirectory("fps-optional")
        defer { try? FileManager.default.removeItem(at: work) }
        let located = try payload(work.appending(path: "payload"), counter: false)
        #expect(located.fpsCounter == nil)
        #expect(!files(located, work, counter: work.appending(path: "support/fps-counter.dylib"))
            .contains { $0.name == "fps-counter.dylib" })
    }

    @Test("The run script and the Makefile use the names in cartouche_identity.h")
    func sharedNames() throws {
        let counter = try IdentityTests.headerDefine("CARTOUCHE_FPS_COUNTER_NAME")
        let folder = try IdentityTests.headerDefine("CARTOUCHE_PERFORMANCE_DIR")
        #expect(SupportPaths.fpsCounter.lastPathComponent == counter)
        #expect(SupportPaths.performance.lastPathComponent == folder)
        let script = try String(contentsOf: IdentityTests.repoRoot.appending(path: "dylib/feats/compat_run.sh"), encoding: .utf8)
        #expect(script.contains("fps_counter=\"$np_support/\(counter)\""))
        #expect(script.contains("fps_dir=\"$np_support/\(folder)/incoming/$app_id-"))
        let makefile = try String(contentsOf: IdentityTests.repoRoot.appending(path: "Makefile"), encoding: .utf8)
        #expect(makefile.contains("FPS_COUNTER       := $(OUT_DIR)/$(call identity,CARTOUCHE_FPS_COUNTER_NAME)"))
    }
}
