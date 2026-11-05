import Foundation
import InstallerKit
import Testing

@testable import NotProtonApp

// Our library reaches a game only through its setup's variable, once the runner's loader has
// taken it, ahead of the frame counter, and always with interpolation off
@Suite("Frame generation launch")
struct FrameGenerationTests {

    @Test("The setup accepts the frame generation variables and still refuses DYLD_*")
    func variables() {
        #expect(GameSetupResolver.isAllowed(name: "CARTOUCHE_FRAMEGEN", value: "1"))
        #expect(GameSetupResolver.isAllowed(name: "CARTOUCHE_FRAMEGEN_STATS", value: "1"))
        #expect(GameSetupResolver.isAllowed(name: "CARTOUCHE_FRAMEGEN_TEMPORAL", value: "off"))
        #expect(!GameSetupResolver.isAllowed(name: "CARTOUCHE_FRAMEGENX", value: "1"))
        // Only the launch turns interpolation off; no setup can turn it on
        #expect(!GameSetupResolver.isAllowed(name: "CARTOUCHE_FRAMEGEN_INTERPOLATE", value: "1"))
        #expect(!GameSetupResolver.isAllowed(name: "DYLD_INSERT_LIBRARIES", value: "/x.dylib"))
    }

    @Test("The launcher tries the library before the frame counter and before the game starts")
    func launcherOrder() throws {
        let work = try scratchDirectory("framegen-launcher")
        defer { try? FileManager.default.removeItem(at: work) }
        let wine = WineRunner(root: work, loader: work.appending(path: "wine"), server: work.appending(path: "wineserver"),
                              dllPath: "")
        let script = GameLauncher.script(exe: work.appending(path: "game.exe"), prefix: work.appending(path: "pfx"),
                                         wine: wine)
        let ours = try #require(script.range(of: FrameGeneration.marker))
        let counter = try #require(script.range(of: GameLauncher.fpsMarker))
        let exec = try #require(script.range(of: "\nexec "))
        #expect(ours.lowerBound < counter.lowerBound && counter.lowerBound < exec.lowerBound)
    }

    // The block alone, with a loader standing in for Wine that writes the probe marker or not
    private func run(accepts: Bool, variable: String?, preset: String = "") throws -> String {
        let work = try scratchDirectory("framegen-block")
        defer { try? FileManager.default.removeItem(at: work) }
        let library = work.appending(path: "framegen.dylib")
        try Data("lib".utf8).write(to: library)
        let loader = work.appending(path: "wine")
        let body = accepts ? "[ -n \"$CARTOUCHE_FRAMEGEN_PROBE\" ] && echo x86_64 > \"$CARTOUCHE_FRAMEGEN_PROBE\"\n" : "exit 0\n"
        try Data(("#!/bin/sh\n" + body).utf8).write(to: loader)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: loader.path)
        let lines = ["export WINELOADER=\(GameLauncher.quote(loader.path))"]
            + (variable.map { ["export CARTOUCHE_FRAMEGEN=\($0)"] } ?? [])
            + (preset.isEmpty ? [] : ["export DYLD_INSERT_LIBRARIES=\(preset)"])
            + FrameGeneration.launcherLines(library: library, stats: work.appending(path: "logs dir"))
            + [#"echo "DYLD=${DYLD_INSERT_LIBRARIES:-} DIR=${CARTOUCHE_FRAMEGEN_DIR:-} INTERPOLATE=${CARTOUCHE_FRAMEGEN_INTERPOLATE-unset}""#,
               #"ls "${TMPDIR:-/tmp}" | grep -c "cartouche-framegen-$$" || true"#]
        let script = work.appending(path: "launch")
        try Data(lines.joined(separator: "\n").utf8).write(to: script)
        let result = try Shell.run("/bin/sh", [script.path], environment: ["PATH": "/usr/bin:/bin", "TMPDIR": work.path])
        return result.stdout.replacingOccurrences(of: work.path, with: "<work>")
    }

    @Test("A loader that takes the library gets it first, with the stats folder")
    func accepted() throws {
        let out = try run(accepts: true, variable: "1", preset: "/overlay.dylib")
        #expect(out.contains("framegen: on for this launch"))
        #expect(out.contains("DYLD=<work>/framegen.dylib:/overlay.dylib DIR=<work>/logs dir INTERPOLATE=0"))
        #expect(out.hasSuffix("0\n"), "the probe marker is removed")
    }

    @Test("A loader that refuses it, or a game without the variable, starts without it")
    func refused() throws {
        let refused = try run(accepts: false, variable: "1")
        #expect(refused.contains("framegen: refused by this runner"))
        #expect(refused.contains("DYLD= DIR= INTERPOLATE=unset"))
        let off = try run(accepts: true, variable: nil)
        #expect(!off.contains("framegen:"))
        #expect(off.contains("DYLD= DIR= INTERPOLATE=unset"))
        #expect(!(try run(accepts: true, variable: "0")).contains("framegen:"))
    }

    @Test("A payload with the library deploys it without stopping Steam; one without still installs")
    func deployed() throws {
        let work = try scratchDirectory("framegen-deploy")
        defer { try? FileManager.default.removeItem(at: work) }
        let files = FileManager.default
        let root = work.appending(path: "payload")
        try files.createDirectory(at: root.appending(path: "signatures/macos.arm64"), withIntermediateDirectories: true)
        try files.createDirectory(at: root.appending(path: "fonts"), withIntermediateDirectories: true)
        for name in [SupportPaths.dylibName, "overlay-shim.dylib", "iconmaker", "appinfo", "run"] {
            try Data(name.utf8).write(to: root.appending(path: name))
        }
        try Data("100\n".utf8).write(to: root.appending(path: "build-time"))
        try Data("{}".utf8).write(to: root.appending(path: "signatures/macos.arm64/1.json"))
        try Data("font".utf8).write(to: root.appending(path: "fonts/arial.ttf"))
        #expect(try InstallPayload.locate(root: root).framegen == nil)
        try Data("framegen".utf8).write(to: root.appending(path: SupportPaths.framegenName))
        let located = try InstallPayload.locate(root: root)
        #expect(located.framegen?.lastPathComponent == "framegen.dylib")

        let support = work.appending(path: "support")
        let destination = support.appending(path: SupportPaths.framegenName)
        let deployed = DeploymentContent.files(
            payload: located, bridgePayload: BridgePayload.Located(sources: []), app: work.appending(path: "Steam.app"),
            bridge: support.appending(path: "bridge"), signatures: support.appending(path: "signatures"),
            fonts: support.appending(path: "fonts"), overlayShim: support.appending(path: "overlay-shim.dylib"),
            iconmaker: support.appending(path: "iconmaker"), appinfo: support.appending(path: "appinfo"),
            compatTools: work.appending(path: "compatibilitytools.d"), tools: [], runners: support.appending(path: "runners"),
            framegen: destination)
        let file = try #require(deployed.first { $0.name == SupportPaths.framegenName })
        #expect(file.destination == destination)
        #expect(!file.needsClientStopped)
    }

    @Test("The run script and the Makefile use the name in cartouche_identity.h")
    func sharedNames() throws {
        let name = try IdentityTests.headerDefine("CARTOUCHE_FRAMEGEN_NAME")
        #expect(SupportPaths.framegen.lastPathComponent == name)
        let script = try String(contentsOf: IdentityTests.repoRoot.appending(path: "dylib/feats/compat_run.sh"), encoding: .utf8)
        #expect(script.contains("framegen=\"$np_support/\(name)\""))
        let makefile = try String(contentsOf: IdentityTests.repoRoot.appending(path: "Makefile"), encoding: .utf8)
        #expect(makefile.contains("FRAMEGEN          := $(OUT_DIR)/$(call identity,CARTOUCHE_FRAMEGEN_NAME)"))
    }
}
