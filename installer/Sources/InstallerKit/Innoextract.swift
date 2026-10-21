//// Cartouche.app carries its own innoextract copy in Contents/Helpers (built by installer/innoextract/build.sh);
//// a Homebrew copy is only a fallback for development.

import Foundation

public enum Innoextract {

    // The pinned release the bundled copy is built from.
    public static let version = "1.10-dev-2025-01-07"

    // CARTOUCHE_INNOEXTRACT, then the bundled copy, then Homebrew.
    public static func path(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundled: [URL] = bundledCandidates(),
        fallbacks: [String] = ["/opt/homebrew/bin/innoextract", "/usr/local/bin/innoextract"]
    ) -> String? {
        let fm = FileManager.default
        var candidates: [String] = []
        #if DEBUG
        // Debug/test override only: a release build must not run an arbitrary binary from env.
        if let forced = environment["CARTOUCHE_INNOEXTRACT"], !forced.isEmpty { candidates.append(forced) }
        #endif
        candidates += bundled.map { $0.path(percentEncoded: false) }
        candidates += fallbacks
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }

    public static func bundledCandidates(main: Bundle = .main) -> [URL] {
        var urls = [main.bundleURL.appending(path: "Contents/Helpers/innoextract")]
        if let exe = main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent() {
            urls.append(exe.appending(path: "../Helpers/innoextract").standardizedFileURL)
            urls.append(exe.appending(path: "innoextract"))
        }
        return urls
    }

    public struct SectionMissing: Error, Sendable, Equatable {
        public let section: String
        public let detail: String
    }

    // `innoextract -s -I <section>` unpacks only that section's tree, landing at <dir>/<section>.
    // Silent mode prints nothing on success, so the produced directory is the success signal.
    public static func extract(
        setup: URL, section: String, into dir: URL, tool: String, runner: any ToolRunning
    ) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = try runner.run(tool, ["-s", "-I", section, "-d", dir.path(percentEncoded: false), setup.path(percentEncoded: false)])
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.appending(path: section).path(percentEncoded: false), isDirectory: &isDirectory),
              isDirectory.boolValue else {
            let tail = out.split(whereSeparator: \.isNewline).suffix(5).joined(separator: " ").trimmingCharacters(in: .whitespaces)
            throw SectionMissing(section: section, detail: tail)
        }
    }
}

public protocol ToolRunning: Sendable {
    func run(_ tool: String, _ arguments: [String]) throws -> String
}

public struct ToolTimedOut: Error, Sendable {
    public let tool: String
}

public struct ProcessToolRunner: ToolRunning {
    public init(timeout: TimeInterval = 120) { self.timeout = timeout }

    // innoextract --list on a damaged archive can run forever; bound it.
    public let timeout: TimeInterval

    public func run(_ tool: String, _ arguments: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(filePath: tool)
        p.arguments = arguments
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        p.standardInput = FileHandle.nullDevice
        try p.run()
        nonisolated(unsafe) var data = Data()
        let done = DispatchGroup()
        done.enter()
        DispatchQueue.global().async {
            data = out.fileHandleForReading.readDataToEndOfFile()
            done.leave()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            _ = done.wait(timeout: .now() + 5)
            throw ToolTimedOut(tool: tool)
        }
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
