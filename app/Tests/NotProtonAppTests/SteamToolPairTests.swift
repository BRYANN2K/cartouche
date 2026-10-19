import CartoucheIdentity
import Foundation
import Testing

@testable import NotProtonApp

// The runner and graphics backend pairs Steam is offered, written beside the runner
// tool list, which keeps its baseline (SteamToolListTests). Scratch folders only.
@Suite("Steam tools per runner and backend")
struct SteamToolPairTests {

    static let release = SupportedRunners.build(id: "26.3.0.39832")!
    static let fex = SupportedRunners.build(id: "27.0.0.41073-fex")!

    // Two CrossOver clones; only the 26.3 one carries D3DMetal
    func runnersFolder(_ work: URL) throws -> URL {
        let runners = work.appending(path: "runners")
        let fm = FileManager.default
        for build in [Self.release, Self.fex] {
            try fm.createDirectory(at: SupportPaths.clonedRoot(forBuild: build.id, runners: runners).appending(path: "lib/wine"),
                                   withIntermediateDirectories: true)
        }
        try fm.createDirectory(
            at: SupportPaths.clonedRoot(forBuild: Self.release.id, runners: runners)
                .appending(path: "lib64/apple_gptk/external/D3DMetal.framework"),
            withIntermediateDirectories: true)
        return runners
    }

    static let p = SupportPaths.toolPrefix

    static let pairs = [
        "\(p)-fex-41073-dxmt\t27.0.0.41073-fex\tfex\tdxmt\tCrossOver 2026 10 15-ARM64 - FEX · DXMT",
        "\(p)-fex-41073-dxvk\t27.0.0.41073-fex\tfex\tdxvk\tCrossOver 2026 10 15-ARM64 - FEX · DXVK",
        "\(p)-fex-41073-wined3d\t27.0.0.41073-fex\tfex\twined3d\tCrossOver 2026 10 15-ARM64 - FEX · wined3d",
        "\(p)-fex-rosetta-41073-dxmt\t27.0.0.41073-fex\trosetta\tdxmt\tCrossOver 2026 10 15-ARM64 - Rosetta · DXMT",
        "\(p)-fex-rosetta-41073-dxvk\t27.0.0.41073-fex\trosetta\tdxvk\tCrossOver 2026 10 15-ARM64 - Rosetta · DXVK",
        "\(p)-fex-rosetta-41073-wined3d\t27.0.0.41073-fex\trosetta\twined3d\tCrossOver 2026 10 15-ARM64 - Rosetta · wined3d",
        "\(p)-26.3-d3dmetal\t26.3.0.39832\trosetta\td3dmetal\tCrossOver 26.3 · D3DMetal",
        "\(p)-26.3-dxmt\t26.3.0.39832\trosetta\tdxmt\tCrossOver 26.3 · DXMT",
        "\(p)-26.3-dxvk\t26.3.0.39832\trosetta\tdxvk\tCrossOver 26.3 · DXVK",
        "\(p)-26.3-wined3d\t26.3.0.39832\trosetta\twined3d\tCrossOver 26.3 · wined3d",
    ]

    @Test("Two runners and their backends give every valid pair, named \"<runner> · <backend>\", in the runner tools' order")
    func everyValidPair() throws {
        let work = try scratchDirectory("tool-pairs")
        defer { try? FileManager.default.removeItem(at: work) }
        let runners = try runnersFolder(work)
        let file = work.appending(path: "tools")
        try CompatToolList.sync(runners: runners, bridge: work.appending(path: "bridge"), file: file,
                                compatTools: work.appending(path: "compatibilitytools.d"), fexAvailable: true)

        let written = try String(contentsOf: work.appending(path: "backend-tools"), encoding: .utf8)
        #expect(written == Self.pairs.map { $0 + "\n" }.joined())
        // The runner tools themselves are untouched
        #expect(try String(contentsOf: file, encoding: .utf8).split(separator: "\n").count == 3)
        #expect(!written.contains("fex-41073-d3dmetal") && !written.contains("rosetta-41073-d3dmetal"),
                "no D3DMetal for a CrossOver without it, nor with FEX")
    }

    @Test("No pair clashes with a runner tool, another pair, or a NotProton tool name")
    func noClash() throws {
        let tools = SupportedRunners.tools(for: SupportedRunners.all, fexAvailable: true)
        // Every pinned build with every backend, so the check covers the widest list
        let pairs = SupportedRunners.backendTools(for: tools) { _ in BackendSupport.preference }
        let names = pairs.map(\.name)
        #expect(Set(names).count == names.count)
        #expect(Set(names).isDisjoint(with: tools.map(\.name)))
        let other = CARTOUCHE_OTHER_STEAM_PREFIX
        for name in names {
            #expect(name.hasPrefix(SupportPaths.toolPrefix))
            #expect(!name.localizedCaseInsensitiveContains(other))
            #expect(name.count < 64, "the dylib keeps names under 64 bytes")
        }
        for pair in pairs { #expect(pair.display.utf8.count < 96, "the dylib keeps displays under 96 bytes") }
    }

    @Test("On macOS 15 the FEX tools have no pairs either")
    func sequoia() throws {
        let work = try scratchDirectory("tool-pairs-15")
        defer { try? FileManager.default.removeItem(at: work) }
        let runners = try runnersFolder(work)
        let file = work.appending(path: "tools")
        try CompatToolList.sync(runners: runners, bridge: work.appending(path: "bridge"), file: file,
                                compatTools: work.appending(path: "compatibilitytools.d"), fexAvailable: false)
        let written = try String(contentsOf: work.appending(path: "backend-tools"), encoding: .utf8)
        #expect(written == Self.pairs.filter { !$0.contains("\tfex\t") }.map { $0 + "\n" }.joined())
    }

    @Test("The registry reads the same pairs the list file holds, and the dylib reads that file name")
    func registryAgrees() throws {
        let work = try scratchDirectory("tool-pairs-registry")
        defer { try? FileManager.default.removeItem(at: work) }
        let runners = try runnersFolder(work)
        let file = work.appending(path: "tools")
        try CompatToolList.sync(runners: runners, bridge: work.appending(path: "bridge"), file: file,
                                compatTools: work.appending(path: "compatibilitytools.d"), fexAvailable: true)
        let pairs = RunnerRegistry.backendTools(runners: runners, file: file)
        let written = try String(contentsOf: work.appending(path: "backend-tools"), encoding: .utf8)
        #expect(CompatToolList.backendContents(pairs) == written || !CompatTool.Flavor.fexAvailable)
        #expect(SupportPaths.backendToolList.lastPathComponent == (try IdentityTests.headerDefine("CARTOUCHE_BACKEND_TOOL_LIST")))
        let compat = try String(contentsOf: IdentityTests.repoRoot.appending(path: "dylib/feats/compat.c"), encoding: .utf8)
        #expect(compat.contains("CARTOUCHE_SUPPORT_DIR \"/\" CARTOUCHE_BACKEND_TOOL_LIST"))
    }
}
