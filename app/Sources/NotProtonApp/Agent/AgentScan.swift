import Foundation
import RetroArchKit

// The last thing between a tool's answer and the wire: every response passes
// through the scan, which rewrites what must never leave the app — store
// tokens, keychain secrets, paths outside the allowed roots — before a byte
// reaches the client. Read tools are scanned like every other tool: no tool
// gets a pass.
enum AgentScan {

    // What a planted secret would look like. Broad on purpose: a false
    // positive only hides a string; a miss leaks a credential.
    static let tokenPatterns = [
        #"[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{10,}"#,       // JWTs
        #"(?i)(token|secret|password|sessionid|apikey|api_key|private_key)"# + #"["'\s:=]+[A-Za-z0-9_./+-]{16,}"#,
        #"-----BEGIN [A-Z ]*PRIVATE KEY-----[^-]*-----END"#,
        #"sk-[A-Za-z0-9]{16,}"#,                                             // Anthropic/OpenAI keys
        #"ghp_[A-Za-z0-9]{20,}"#,
    ]

    // Compiled once: every answer string runs the scan, so patterns are kept
    // ready instead of built per leaf.
    static let tokenRegexes = tokenPatterns.compactMap {
        try? NSRegularExpression(pattern: $0)
    }
    static let pathRegex = try? NSRegularExpression(
        pattern: #"~?(/(?:Users|Volumes|private|var|tmp|opt|usr|etc|System|Library|Applications|home|mnt|data|root)[^\n"'`)\r]*)+"#)
    static let wineUserRegex = try? NSRegularExpression(
        pattern: #"(?i)[a-z]:\\users\\"# + NSRegularExpression.escapedPattern(for: NSUserName()))

    static let placeholder = "[redacted]"
    static let homePlaceholder = "~"

    // One string, scrubbed: tokens out entirely, home paths shortened to ~,
    // paths outside the allowed roots cut to the file name.
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

    // Paths outside the roots are cut to the file name, so an agent never
    // learns where the user's files sit; allowed paths stay but are shortened
    // to ~/… — enough to act on through the tools, not enough to reveal the
    // account name.
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
        // A match under an allowed root keeps its tail, spaces included —
        // which is why the path pattern runs to a quote or newline, not a
        // space.
        let allowed = roots
            .map { $0.standardizedFileURL.path(percentEncoded: false) }
            .filter { !$0.isEmpty }
        guard let pathRegex else { return out }
        return replacingMatches(pathRegex, in: out) { path in
            // ~/… strings keep working for the client; expand for the test.
            let real = path.hasPrefix(homePlaceholder)
                ? homePath + path.dropFirst(homePlaceholder.count) : path
            if allowed.contains(where: { real == $0 || real.hasPrefix($0 + "/") }) {
                return path
            }
            // Keep the file name; the folders stay private.
            return real.components(separatedBy: "/").last.map { "…/\($0)" } ?? "…"
        }
    }

    // Where a path an agent passed may live: inside a root after symlinks and
    // ".." resolve — so pfx/dosdevices/z:/… (which points at /) or a granted
    // folder's link to the home directory stay refused. A literal dosdevices
    // hop or a ".." component is refused before resolving.
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

    // Scans a decoded JSON tree: strings are scrubbed, the shape is kept.
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
