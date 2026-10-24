import Foundation

// String.compare(options: .numeric) puts 0.2.0-beta.1 after 0.2.0; packaging/release.py version_key agrees.
enum CartoucheVersion {

    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        guard let a = Parsed(lhs), let b = Parsed(rhs) else {
            return lhs.compare(rhs, options: .numeric)
        }
        for i in 0..<max(a.core.count, b.core.count) {
            let x = i < a.core.count ? a.core[i] : 0
            let y = i < b.core.count ? b.core[i] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        switch (a.pre.isEmpty, b.pre.isEmpty) {
        case (true, true): return .orderedSame
        case (true, false): return .orderedDescending
        case (false, true): return .orderedAscending
        case (false, false): break
        }
        for (x, y) in zip(a.pre, b.pre) {
            let order = compareIdentifier(x, y)
            if order != .orderedSame { return order }
        }
        return a.pre.count == b.pre.count ? .orderedSame : (a.pre.count < b.pre.count ? .orderedAscending : .orderedDescending)
    }

    // Numeric identifiers compare as numbers and sort before words
    private static func compareIdentifier(_ x: String, _ y: String) -> ComparisonResult {
        switch (number(x), number(y)) {
        case let (m?, n?): return m == n ? .orderedSame : (m < n ? .orderedAscending : .orderedDescending)
        case (_?, nil): return .orderedAscending
        case (nil, _?): return .orderedDescending
        case (nil, nil): return x == y ? .orderedSame : (x < y ? .orderedAscending : .orderedDescending)
        }
    }

    fileprivate static func number(_ text: String) -> Int? {
        !text.isEmpty && text.allSatisfy { $0.isASCII && $0.isNumber } ? Int(text) : nil
    }

    private struct Parsed {
        let core: [Int]
        let pre: [String]

        init?(_ version: String) {
            let withoutBuild = version.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)[0]
            let parts = withoutBuild.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            let core = parts[0].split(separator: ".", omittingEmptySubsequences: false).map { CartoucheVersion.number(String($0)) }
            guard !core.isEmpty, !core.contains(nil) else { return nil }
            self.core = core.compactMap { $0 }
            pre = parts.count > 1 ? parts[1].split(separator: ".").map(String.init) : []
            if parts.count > 1 && pre.isEmpty { return nil }
        }
    }
}
