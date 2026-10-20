// Reads files and runs only innoextract.

import Foundation

public struct MissingPart: Sendable, Equatable {
    public let file: String
    // Optional per the manifest; shown non-blocking, otherwise blocking.
    public let mayBeOptional: Bool
}

public struct InstallerAnalysis: Sendable {
    public let folder: URL
    public let scan: PartScan
    public let manifest: ChecksumManifest?
    public let inno: InnoReport?
    public let innoProblem: InnoInspector.Failure?
    public let name: String
    // Set when the installer unpacks through its own helper programs (ExternalUnpacker).
    public let unpacker: ExternalUnpacker?
    public let classification: FolderClassification
    public var checksums: [URL: ChecksumResult] = [:]
    public var seconds: Double = 0

    public var space: SpaceEstimate {
        SpaceEstimate.from(compressed: scan.totalSize, heavy: (inno?.heavyDecompression ?? false) || unpacker != nil)
    }

    public var missing: [MissingPart] {
        Analyzer.missingParts(scan: scan, manifest: manifest, checksums: checksums)
    }

    public var damaged: [String] { Checksums.damaged(checksums) }

    public var verified: Bool { !checksums.isEmpty }
    public var checksumsOK: Bool { verified && checksums.values.allSatisfy { $0 == .ok || $0 == .absent } && damaged.isEmpty }

    // A game that is already installed: nothing to run, it is imported as it is.
    public var isInstalledGame: Bool { classification.kind == .installedGame }

    public var blockingProblems: [String] {
        if isInstalledGame { return [] }
        var problems: [String] = []
        if scan.setup == nil { problems.append("setup") }
        problems += missing.filter { !$0.mayBeOptional }.map(\.file)
        problems += damaged
        return problems
    }

    public var canInstall: Bool { blockingProblems.isEmpty }
}

public enum Analyzer {

    public static func folder(for dropped: URL) -> URL {
        let isDirectory = (try? dropped.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        return isDirectory ? dropped : dropped.deletingLastPathComponent()
    }

    public static func missingParts(
        scan: PartScan, manifest: ChecksumManifest?, checksums: [URL: ChecksumResult] = [:]
    ) -> [MissingPart] {
        var names = Set(scan.missing)
        let fm = FileManager.default
        for entry in manifest?.entries ?? [] where checksums[entry.file] == .absent
            || !fm.fileExists(atPath: entry.file.path(percentEncoded: false)) {
            names.insert(entry.file.lastPathComponent)
        }
        let optional = manifest?.mentionsOptionalParts ?? false
        return names.sorted().map { MissingPart(file: $0, mayBeOptional: optional) }
    }

    public static func inspect(
        _ dropped: URL, tool: String? = Innoextract.path(), runner: any ToolRunning = ProcessToolRunner()
    ) throws -> InstallerAnalysis {
        let classification = DroppedFolder.classify(folder(for: dropped))
        let folder = classification.root
        if classification.kind == .installedGame {
            return InstallerAnalysis(
                folder: folder, scan: PartScan(folder: folder, setup: nil, parts: [], missing: []), manifest: nil,
                inno: nil, innoProblem: nil, name: GameName.clean(folder.lastPathComponent), unpacker: nil,
                classification: classification
            )
        }
        let scan = try PartScanner.scan(folder)
        let manifest = Checksums.findManifest(in: folder).flatMap { try? Checksums.parse($0) }
        var inno: InnoReport?
        var problem: InnoInspector.Failure?
        if let setup = scan.setup {
            do { inno = try InnoInspector.inspect(setup, tool: tool, runner: runner) }
            catch let failure as InnoInspector.Failure { problem = failure }
            catch { problem = .notInno("\(error)") }
        }
        return InstallerAnalysis(
            folder: folder, scan: scan, manifest: manifest, inno: inno, innoProblem: problem,
            name: GameName.clean(folder.lastPathComponent),
            unpacker: ExternalUnpacker.detect(inno: inno, folder: folder),
            classification: classification
        )
    }

    public static func analyze(
        _ dropped: URL, verify: Bool = true, tool: String? = Innoextract.path(),
        runner: any ToolRunning = ProcessToolRunner()
    ) async throws -> InstallerAnalysis {
        let start = Date()
        var analysis = try inspect(dropped, tool: tool, runner: runner)
        if verify, let manifest = analysis.manifest {
            analysis.checksums = try await Checksums.verify(manifest, root: analysis.folder)
        }
        analysis.seconds = Date().timeIntervalSince(start)
        return analysis
    }
}

public enum Disk {
    public static func freeBytes(at url: URL) -> Int64? {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path(percentEncoded: false)), probe.pathComponents.count > 1 {
            probe = probe.deletingLastPathComponent()
        }
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
