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
        // Steam session tokens, bearer tokens, keychain-style secrets
        #"[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{10,}"#,       // JWTs
        #"(?i)(token|secret|password|sessionid|apikey|api_key|private_key)"# + #"["'\s:=]+[A-Za-z0-9_./+-]{16,}"#,
        #"-----BEGIN [A-Z ]*PRIVATE KEY-----[^-]*-----END"#,
        #"sk-[A-Za-z0-9]{16,}"#,                                             // Anthropic/OpenAI keys
        #"ghp_[A-Za-z0-9]{20,}"#,
    ]

    static let placeholder = "[redacted]"
    static let homePlaceholder = "~"

    // One string, scrubbed: tokens out entirely, home paths shortened to ~,
    // paths outside the allowed roots cut to the file name.
    static func scrub(_ text: String, under roots: [URL], home: URL) -> String {
        var out = text
        for pattern in tokenPatterns {
            out = replacingMatches(pattern, in: out) { _ in placeholder }
        }
        return scrubPaths(out, under: roots, home: home)
    }

    // Paths outside the roots are cut to the file name, so an agent never
    // learns where the user's files sit; allowed paths stay but are shortened
    // to ~/… — enough to act on through the tools, not enough to reveal the
    // account name.
    static func scrubPaths(_ text: String, under roots: [URL], home: URL) -> String {
        var out = text
        let homePath = home.standardizedFileURL.path(percentEncoded: false)
        if !homePath.isEmpty {
            out = out.replacingOccurrences(of: homePath, with: homePlaceholder)
        }
        // Absolute paths that survived the home rewrite and sit outside the
        // allowed roots collapse to their file name.
        let allowed = roots.map { $0.standardizedFileURL.path(percentEncoded: false) }
        out = replacingMatches(#"~?(/(?:Users|Volumes|private|var|tmp|opt|usr|etc|System|Library|Applications|home|mnt|data|root)[^\s"'`)]*)+"#, in: out) { path in
            // ~/… strings keep working for the client; strip the ~ for the test.
            let real = path.hasPrefix(homePlaceholder) ? homePath + path.dropFirst(homePlaceholder.count) : path
            if allowed.contains(where: { real == $0 || real.hasPrefix($0 + "/") }) {
                return path.hasPrefix(homePlaceholder) ? homePlaceholder + real.dropFirst(homePath.count) : real
            }
            // Keep the file name; the folders stay private.
            return real.components(separatedBy: "/").last.map { "…/\($0)" } ?? "…"
        }
        return out
    }

    // Where the isAllowed check lives for tool arguments (file paths agents
    // pass in). Reads outside the roots are refused outright.
    static func isAllowed(_ url: URL, under roots: [URL]) -> Bool {
        let real = url.standardizedFileURL.path(percentEncoded: false)
        return roots.contains { root in
            let base = root.standardizedFileURL.path(percentEncoded: false)
            return real == base || real.hasPrefix(base + "/")
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
        _ pattern: String, in text: String, _ body: (String) -> String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        var out = text
        for match in regex.matches(in: out, range: NSRange(out.startIndex..., in: out)).reversed() {
            guard let range = Range(match.range, in: out) else { continue }
            out.replaceSubrange(range, with: body(String(out[range])))
        }
        return out
    }
}
