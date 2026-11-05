import Foundation
import Testing

// Text outputs that must not change by accident, kept byte for byte under Goldens/.
// CARTOUCHE_UPDATE_GOLDENS=1 rewrites them from the current output instead of comparing.
enum Golden {
    static let folder = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Goldens")
    static let repo = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    static var updating: Bool { ProcessInfo.processInfo.environment["CARTOUCHE_UPDATE_GOLDENS"] == "1" }

    // Scratch paths and the home folder read the same on every Mac
    static func scrub(_ text: String, scratch: URL? = nil) -> String {
        var out = text
        if let scratch {
            let path = scratch.path(percentEncoded: false).trimmingSuffix("/")
            for form in [scratch.resolvingSymlinksInPath().path(percentEncoded: false).trimmingSuffix("/"), path,
                         path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : "/private" + path] {
                out = out.replacingOccurrences(of: form, with: "$SCRATCH")
            }
        }
        return out.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
            .trimmingSuffix("/"), with: "$HOME")
    }

    static func check(_ actual: String, _ name: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let url = folder.appending(path: name)
        if updating {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(actual.utf8).write(to: url)
            return
        }
        guard let expected = try? Data(contentsOf: url) else {
            Issue.record("No golden at Goldens/\(name). Run with CARTOUCHE_UPDATE_GOLDENS=1 to write it.",
                         sourceLocation: sourceLocation)
            return
        }
        guard expected != Data(actual.utf8) else { return }
        Issue.record(Comment(rawValue: "Goldens/\(name) differs (CARTOUCHE_UPDATE_GOLDENS=1 rewrites it if the change is wanted):\n"
                                       + diff(expected: url, actual: actual)), sourceLocation: sourceLocation)
    }

    static func diff(expected: URL, actual: String) -> String {
        let scratch = URL.temporaryDirectory.appending(path: "golden-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        guard (try? Data(actual.utf8).write(to: scratch)) != nil else { return actual }
        let diff = Process()
        diff.executableURL = URL(filePath: "/usr/bin/diff")
        diff.arguments = ["-u", "--label", "golden", "--label", "current",
                          expected.path(percentEncoded: false), scratch.path(percentEncoded: false)]
        let pipe = Pipe()
        diff.standardOutput = pipe
        guard (try? diff.run()) != nil else { return actual }
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        diff.waitUntilExit()
        return String(decoding: out, as: UTF8.self)
    }
}

private extension String {
    func trimmingSuffix(_ suffix: String) -> String {
        hasSuffix(suffix) && count > suffix.count ? String(dropLast(suffix.count)) : self
    }
}
