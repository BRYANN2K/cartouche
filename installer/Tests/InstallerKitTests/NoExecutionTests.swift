import Foundation
import Testing
@testable import InstallerKit

// Every file of the dropped folder is an executable script that leaves a marker
// if anything runs it. Analysis must leave no marker.
@Suite("No execution during analysis")
struct NoExecutionTests {

    private func trapFolder() throws -> (folder: URL, marker: URL) {
        let root = try tempFolder([:])
        let marker = root.appending(path: "ran")
        let folder = root.appending(path: "Sample Game")
        let trap = "#!/bin/sh\ntouch '\(marker.path(percentEncoded: false))'\n"
        for name in ["setup.exe", "data-01.bin", "data-02.bin", "unarc.dll", "MD5/checksums.md5"] {
            try executable(folder.appending(path: name), trap)
        }
        return (folder, marker)
    }

    @Test("Analysis with a recording innoextract never runs a file from the folder")
    func fakeTool() async throws {
        let (folder, marker) = try trapFolder()
        let log = try tempFolder([:]).appending(path: "calls")
        let tool = try tempFolder([:]).appending(path: "innoextract")
        try executable(tool, "#!/bin/sh\necho \"$@\" >> '\(log.path(percentEncoded: false))'\necho 'Not a supported Inno Setup installer!'\n")

        let analysis = try await Analyzer.analyze(folder, tool: tool.path(percentEncoded: false))
        #expect(analysis.scan.setup?.lastPathComponent == "setup.exe")
        #expect(!FileManager.default.fileExists(atPath: marker.path(percentEncoded: false)))
        // Only innoextract ran, once, reading setup.exe as a file.
        let calls = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
        #expect(calls == ["--info \(folder.appending(path: "setup.exe").path(percentEncoded: false))"])
    }

    @Test("Analysis with the real innoextract never runs a file from the folder",
          .enabled(if: Innoextract.path() != nil, "innoextract is not installed, so this check is skipped"))
    func realTool() async throws {
        let (folder, marker) = try trapFolder()
        let analysis = try await Analyzer.analyze(folder)
        #expect(analysis.innoProblem != nil)
        #expect(!FileManager.default.fileExists(atPath: marker.path(percentEncoded: false)))
    }

    // The analysis files read; only Innoextract.swift may start a process, and
    // only for the tool path it is given.
    @Test("Only the tool runner can start a process in the analysis code")
    func noOtherLauncher() throws {
        let sources = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/InstallerKit")
        let analysisFiles = ["Analysis.swift", "PartScanner.swift", "ChecksumManifest.swift", "InnoInspector.swift",
                             "InstallPlan.swift", "GameIndex.swift", "PEVersion.swift"]
        for name in analysisFiles {
            let text = try String(contentsOf: sources.appending(path: name), encoding: .utf8)
            for launcher in ["Process(", "posix_spawn", "NSWorkspace", "execv", "system("] {
                #expect(!text.contains(launcher), "\(name) contains \(launcher)")
            }
        }
    }
}
