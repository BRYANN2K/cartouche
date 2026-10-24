// The hash allowlist for native helper replacements (ADR 0025): a shipped helper may only be
// swapped for a native tool when its bytes match an entry here exactly. The list is empty, so
// every helper runs shipped, under Wine. Corpus files and hashes never leave the Mac.

import CryptoKit
import Foundation

public enum HelperAllowlist {

    // sha256 of the shipped helper file → the native replacement allowed to stand in for it.
    // Exact known versions only; unknown helpers always keep the shipped Windows file.
    public static let replacements: [String: String] = [:]

    // The native replacement allowed for this shipped helper, or nil. Nil means the shipped
    // Windows helper runs: unknown helpers are never replaced.
    public static func nativeReplacement(for helper: URL) -> String? {
        guard !replacements.isEmpty else { return nil }
        guard let hash = sha256(of: helper) else { return nil }
        return replacements[hash]
    }

    public static func sha256(of file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
