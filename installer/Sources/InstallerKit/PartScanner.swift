// Finds the installer exe and its data parts in a dropped folder.

import Foundation

public struct InstallerPart: Sendable, Equatable {
    public let url: URL
    public let prefix: String
    public let number: Int
    public let size: Int64
}

public struct PartScan: Sendable {
    public let folder: URL
    public let setup: URL?
    public let parts: [InstallerPart]
    // File names absent from the numbering, e.g. "data-03.bin" when 01, 02 and 04 exist.
    public let missing: [String]

    public var totalSize: Int64 { parts.reduce(0) { $0 + $1.size } }
}

public enum PartScanner {

    // data-01.bin, setup-1.bin, data_3.bin, game.bin.002
    nonisolated(unsafe) private static let numbered = /^(.*?[-_. ]?)(\d{1,3})(\.bin)$/
    nonisolated(unsafe) private static let split = /^(.*\.bin\.)(\d{3})()$/

    public static func scan(_ folder: URL) throws -> PartScan {
        let fm = FileManager.default
        let names = try fm.contentsOfDirectory(atPath: folder.path(percentEncoded: false))
        var parts: [InstallerPart] = []
        // prefix → (suffix, digit width), to rebuild the names of missing parts
        var shape: [String: (String, Int)] = [:]
        var setup: URL?

        for name in names.sorted() {
            let url = folder.appending(path: name)
            let lower = name.lowercased()
            if lower.hasSuffix(".exe") {
                if setup == nil || lower == "setup.exe" { setup = url }
                continue
            }
            guard let m = (try? numbered.wholeMatch(in: name)) ?? (try? split.wholeMatch(in: name)),
                  let number = Int(m.2) else { continue }
            let prefix = String(m.1)
            shape[prefix] = (String(m.3), m.2.count)
            let size = (try? fm.attributesOfItem(atPath: url.path(percentEncoded: false))[.size] as? Int64) ?? 0
            parts.append(InstallerPart(url: url, prefix: prefix, number: number, size: size))
        }

        var missing: [String] = []
        for (prefix, group) in Dictionary(grouping: parts, by: \.prefix) {
            let have = Set(group.map(\.number)), (suffix, width) = shape[prefix]!
            let first = have.contains(0) ? 0 : 1
            for n in first...(have.max() ?? first) where !have.contains(n) {
                missing.append(prefix + String(repeating: "0", count: max(0, width - String(n).count)) + String(n) + suffix)
            }
        }
        return PartScan(folder: folder, setup: setup,
                        parts: parts.sorted { ($0.prefix, $0.number) < ($1.prefix, $1.number) },
                        missing: missing.sorted())
    }
}
