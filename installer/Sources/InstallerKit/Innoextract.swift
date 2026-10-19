// Where innoextract comes from, and how InstallerKit runs tools.
// Cartouche.app carries its own copy in Contents/Helpers (built by
// installer/innoextract/build.sh); a Homebrew copy is only a fallback for development.

import Foundation

public enum Innoextract {

    // The pinned release the bundled copy is built from.
    public static let version = "1.9"

    // CARTOUCHE_INNOEXTRACT, then the bundled copy, then Homebrew.
    public static func path(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundled: [URL] = bundledCandidates(),
        fallbacks: [String] = ["/opt/homebrew/bin/innoextract", "/usr/local/bin/innoextract"]
    ) -> String? {
        let fm = FileManager.default
        var candidates: [String] = []
        if let forced = environment["CARTOUCHE_INNOEXTRACT"], !forced.isEmpty { candidates.append(forced) }
        candidates += bundled.map { $0.path(percentEncoded: false) }
        candidates += fallbacks
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }

    // Contents/Helpers of the running app, and next to the running binary for the CLI.
    public static func bundledCandidates(main: Bundle = .main) -> [URL] {
        var urls = [main.bundleURL.appending(path: "Contents/Helpers/innoextract")]
        if let exe = main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent() {
            urls.append(exe.appending(path: "../Helpers/innoextract").standardizedFileURL)
            urls.append(exe.appending(path: "innoextract"))
        }
        return urls
    }
}

// Runs a helper tool and returns what it printed. Tests swap it to see every call.
public protocol ToolRunning: Sendable {
    func run(_ tool: String, _ arguments: [String]) throws -> String
}

public struct ProcessToolRunner: ToolRunning {
    public init() {}

    public func run(_ tool: String, _ arguments: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(filePath: tool)
        p.arguments = arguments
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        p.standardInput = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
