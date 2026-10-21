import Foundation
import Testing

@testable import NotProtonApp

// Pins the CrossOver tools Steam is offered, as captured on the baseline. Moving
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

    private static func wineReceipt(_ id: String, in runners: URL) throws {
        let root = runners.appending(path: id)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let receipt = WineRunnerInstaller.Receipt(
            id: id, archiveSHA256: "aa", files: [:], loader: "bin/wine")
        try JSONEncoder().encode(receipt).write(to: root.appending(path: WineRunnerInstaller.receiptName))
    }

    @Test("An installed Cartouche Wine build registers only its manifest flavors after the clones")
    func wineTools() throws {
        let work = try scratchDirectory("toollist-wine")
        defer { try? FileManager.default.removeItem(at: work) }
        let runners = work.appending(path: "runners")
        let id = "wine-crossover-26.3.0-1"
        try Self.wineReceipt(id, in: runners)
        let file = work.appending(path: "tools")

        try CompatToolList.sync(
            runners: runners, bridge: work.appending(path: "bridge"), file: file,
            compatTools: work.appending(path: "compatibilitytools.d"), fexAvailable: true)

        #expect(try String(contentsOf: file, encoding: .utf8) == Self.text([
            "\(Self.p)-\(id)\t\(id)\trosetta\tWine CrossOver 26.3",
        ]))
    }

    @Test("A WineHQ build is not a compatibility tool")
    func wineHQExcluded() throws {
        let work = try scratchDirectory("toollist-winehq")
        defer { try? FileManager.default.removeItem(at: work) }
        let runners = work.appending(path: "runners")
        for build in RunnerManifest.current().builds
        where build.kind == Runner.Kind.wineBuild.rawValue && build.origin != .cartouche {
            try Self.wineReceipt(build.id, in: runners)
        }
        let file = work.appending(path: "tools")

        try CompatToolList.sync(
            runners: runners, bridge: work.appending(path: "bridge"), file: file,
            compatTools: work.appending(path: "compatibilitytools.d"), fexAvailable: true)

        #expect(try String(contentsOf: file, encoding: .utf8) == "")
    }

    @Test("A removed Wine build drops off the list on the next sync")
    func wineRemoval() throws {
        let work = try scratchDirectory("toollist-wine-remove")
        defer { try? FileManager.default.removeItem(at: work) }
        let runners = work.appending(path: "runners")
        let id = "wine-crossover-26.3.0-1"
        try Self.wineReceipt(id, in: runners)
        let file = work.appending(path: "tools")
        let compatTools = work.appending(path: "compatibilitytools.d")

        try CompatToolList.sync(
            runners: runners, bridge: work.appending(path: "bridge"), file: file,
            compatTools: compatTools, fexAvailable: true)
        try FileManager.default.removeItem(at: runners.appending(path: id))
        try CompatToolList.sync(
            runners: runners, bridge: work.appending(path: "bridge"), file: file,
            compatTools: compatTools, fexAvailable: true)

        #expect(try String(contentsOf: file, encoding: .utf8) == "")
    }
}
