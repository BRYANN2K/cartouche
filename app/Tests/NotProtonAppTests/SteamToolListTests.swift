import Foundation
import Testing

@testable import NotProtonApp

// Pins the CrossOver tools Steam is offered, as captured on the P0 baseline. Moving
// CrossOver onto the runner model must leave these names and their order as they are.
@Suite("Steam tool list baseline")
struct SteamToolListTests {

    private static let p = SupportPaths.toolPrefix

    private static let withFEX = [
        "\(p)-fex\t27.0.0.40921-fex\tfex\tCrossOver 2026 08 21-ARM64 - FEX",
        "\(p)-fex-rosetta\t27.0.0.40921-fex\trosetta\tCrossOver 2026 08 21-ARM64 - Rosetta",
        "\(p)-preview\t27.0.0.40921\trosetta\tCrossOver 2026 08 21-X86 - Rosetta",
        "\(p)-fex-41069\t27.0.0.41069-fex\tfex\tCrossOver 2026 10 06-ARM64 - FEX",
        "\(p)-fex-rosetta-41069\t27.0.0.41069-fex\trosetta\tCrossOver 2026 10 06-ARM64 - Rosetta",
        "\(p)-preview-41069\t27.0.0.41069\trosetta\tCrossOver 2026 10 06-X86 - Rosetta",
        "\(p)-fex-41073\t27.0.0.41073-fex\tfex\tCrossOver 2026 10 15-ARM64 - FEX",
        "\(p)-fex-rosetta-41073\t27.0.0.41073-fex\trosetta\tCrossOver 2026 10 15-ARM64 - Rosetta",
        "\(p)-preview-41073\t27.0.0.41073\trosetta\tCrossOver 2026 10 15-X86 - Rosetta",
        "\(p)-26.3\t26.3.0.39832\trosetta\tCrossOver 26.3",
    ]

    private static func text(_ lines: [String]) -> String {
        lines.map { $0 + "\n" }.joined()
    }

    @Test("Every pinned build gives the baseline tools, in the baseline order")
    func everyBuildWithFEX() {
        let tools = SupportedRunners.tools(for: SupportedRunners.all, fexAvailable: true)
        #expect(CompatToolList.contents(tools) == Self.text(Self.withFEX))
    }

    @Test("Without FEX support the FEX tools drop out and the order holds")
    func everyBuildWithoutFEX() {
        let tools = SupportedRunners.tools(for: SupportedRunners.all, fexAvailable: false)
        #expect(CompatToolList.contents(tools) == Self.text(Self.withFEX.filter { !$0.contains("\tfex\t") }))
    }

    @Test("A runners folder holding every pinned build writes the baseline list file")
    func listFile() throws {
        let work = try scratchDirectory("toollist")
        defer { try? FileManager.default.removeItem(at: work) }
        let runners = work.appending(path: "runners")
        for build in SupportedRunners.all {
            try FileManager.default.createDirectory(
                at: SupportPaths.clonedRoot(forBuild: build.id, runners: runners).appending(path: "lib/wine"),
                withIntermediateDirectories: true)
        }
        let file = work.appending(path: "tools")

        try CompatToolList.sync(
            runners: runners, bridge: work.appending(path: "bridge"), file: file,
            compatTools: work.appending(path: "compatibilitytools.d"), fexAvailable: true)

        #expect(try String(contentsOf: file, encoding: .utf8) == Self.text(Self.withFEX))
    }
}
