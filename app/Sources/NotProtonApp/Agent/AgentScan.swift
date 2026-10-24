import Foundation
import RetroArchKit

// Every tool response passes through the scan before a byte reaches the client; no tool gets a pass.
enum AgentScan {

    // Broad on purpose: a false positive only hides a string; a miss leaks a credential.
    static let tokenPatterns = [
        #"[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{10,}"#,       // JWTs
        #"(?i)(token|secret|password|sessionid|apikey|api_key|private_key)"# + #"["'\s:=]+[A-Za-z0-9_./+-]{16,}"#,
        #"-----BEGIN [A-Z ]*PRIVATE KEY-----[^-]*-----END"#,
        #"sk-[A-Za-z0-9]{16,}"#,                                             // Anthropic/OpenAI keys
        #"ghp_[A-Za-z0-9]{20,}"#,
    ]

    static let tokenRegexes = tokenPatterns.compactMap {
        try? NSRegularExpression(pattern: $0)
    }
    static let pathRegex = try? NSRegularExpression(
        pattern: #"~?(/(?:Users|Volumes|private|var|tmp|opt|usr|etc|System|Library|Applications|home|mnt|data|root)[^\n"'`)\r]*)+"#)
    static let wineUserRegex = try? NSRegularExpression(
        pattern: #"(?i)[a-z]:\\users\\"# + NSRegularExpression.escapedPattern(for: NSUserName()))

    static let placeholder = "[redacted]"
    static let homePlaceholder = "~"

    // Tokens out, home paths shortened to ~, paths outside the allowed roots cut to the file name.
    static func scrub(_ text: String, under roots: [URL], home: URL) -> String {
        var out = text
        // Nothing under 16 bytes can carry a token; skip the regex passes.
        if out.count >= 16 {
            for regex in tokenRegexes {
                out = replacingMatches(regex, in: out) { _ in placeholder }
            }
        }
        guard out.contains("/") || out.contains("\\") else { return out }
        return scrubPaths(out, under: roots, home: home)
    }

    static func scrubPaths(_ text: String, under roots: [URL], home: URL) -> String {
        var out = text
        // Wine prints the home folder as C:\users\<name>\ or Z:\Users\<name>\.
        if let wineUserRegex {
            out = replacingMatches(wineUserRegex, in: out) { _ in homePlaceholder }
        }
        let homePath = home.standardizedFileURL.path(percentEncoded: false)
        if !homePath.isEmpty {
            out = out.replacingOccurrences(of: homePath, with: homePlaceholder)
        }
        // An allowed-root match keeps its tail, spaces included - hence the path pattern runs to a quote or newline, not a space.
        let allowed = roots
            .map { $0.standardizedFileURL.path(percentEncoded: false) }
            .filter { !$0.isEmpty }
        guard let pathRegex else { return out }
        return replacingMatches(pathRegex, in: out) { path in
            let real = path.hasPrefix(homePlaceholder)
                ? homePath + path.dropFirst(homePlaceholder.count) : path
            if allowed.contains(where: { real == $0 || real.hasPrefix($0 + "/") }) {
                return path
            }
            return real.components(separatedBy: "/").last.map { "…/\($0)" } ?? "…"
        }
    }

    static func contains(_ url: URL, in roots: [URL]) -> Bool {
        let raw = url.pathComponents
        guard !raw.contains(".."), !raw.contains("dosdevices") else { return false }
        var resolved = url
        var tail: [String] = []
        while resolved.pathComponents.count > 1,
              !FileManager.default.fileExists(atPath: resolved.path(percentEncoded: false)) {
            tail.insert(resolved.lastPathComponent, at: 0)
            resolved = resolved.deletingLastPathComponent()
        }
        let real = resolved.resolvingSymlinksInPath().standardizedFileURL.pathComponents + tail
        return roots.contains { root in
            let base = root.resolvingSymlinksInPath().standardizedFileURL.pathComponents
            return real.count >= base.count && real.prefix(base.count).elementsEqual(base)
        }
    }

    static func scrub(_ value: JSONValue, under roots: [URL], home: URL) -> JSONValue {
        switch value {
        case .string(let text): .string(scrub(text, under: roots, home: home))
        case .array(let items): .array(items.map { scrub($0, under: roots, home: home) })
        case .object(let map): .object(map.mapValues { scrub($0, under: roots, home: home) })
        default: value
        }
    }

    private static func replacingMatches(
        _ regex: NSRegularExpression, in text: String, _ body: (String) -> String
    ) -> String {
        var out = text
        for match in regex.matches(in: out, range: NSRange(out.startIndex..., in: out)).reversed() {
            guard let range = Range(match.range, in: out) else { continue }
            out.replaceSubrange(range, with: body(String(out[range])))
        }
        return out
    }
}
