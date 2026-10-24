
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
    // File names absent from the numbering, e.g. "fg-03.bin" when 01, 02 and 04 exist.
    public let missing: [String]

    public var totalSize: Int64 { parts.reduce(0) { $0 + $1.size } }
}

public enum PartScanner {

    nonisolated(unsafe) private static let numbered = /^(.*?[-_. ]?)(\d{1,3})(\.bin)$/
    nonisolated(unsafe) private static let split = /^(.*\.bin\.)(\d{3})()$/
    nonisolated(unsafe) private static let setupName = /(?i)^(setup|install)/

    // Only the numbered .bin groups that belong to the installer count as parts: those the manifest names, the
    // one named after the setup, else the one main group. A bios2.bin or firmware_1.bin nearby is left alone,
    // so nothing unrelated is listed, hashed or trashed with the installer. `manifest` defaults to the folder's own.
    public static func scan(_ folder: URL, manifest: ChecksumManifest? = nil) throws -> PartScan {
        let fm = FileManager.default
        let names = try fm.contentsOfDirectory(atPath: folder.path(percentEncoded: false))
        var parts: [InstallerPart] = []
        // prefix → (suffix, digit width), to rebuild the names of missing parts
        var shape: [String: (String, Int)] = [:]
        var exes: [URL] = []

        for name in names.sorted() {
            let url = folder.appending(path: name)
            let lower = name.lowercased()
            if lower.hasSuffix(".exe") {
                if !DroppedFolder.isUninstaller(name) { exes.append(url) }
                continue
            }
            guard let m = (try? numbered.wholeMatch(in: name)) ?? (try? split.wholeMatch(in: name)),
                  let number = Int(m.2) else { continue }
            let prefix = String(m.1)
            shape[prefix] = (String(m.3), m.2.count)
            let size = (try? fm.attributesOfItem(atPath: url.path(percentEncoded: false))[.size] as? Int64) ?? 0
            parts.append(InstallerPart(url: url, prefix: prefix, number: number, size: size))
        }

        // setup.exe, then a setup- or install- name, then an installer signature; a game's own program is never picked first.
        let setup = exes.first { $0.lastPathComponent.lowercased() == "setup.exe" }
            ?? exes.first { (try? setupName.firstMatch(in: $0.lastPathComponent)) != nil }
            ?? exes.first(where: DroppedFolder.hasInstallerSignature)
            ?? exes.first
        let groups = Dictionary(grouping: parts, by: \.prefix)
        let kept = installerGroups(groups, setup: setup, folder: folder,
                                   manifest: manifest ?? (groups.count > 0 ? Checksums.installerManifest(in: folder) : nil))
        parts.removeAll { !kept.contains($0.prefix) }

        var missing: [String] = []
        for (prefix, group) in groups where kept.contains(prefix) {
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

    private static func installerGroups(_ groups: [String: [InstallerPart]], setup: URL?, folder: URL,
                                        manifest: ChecksumManifest?) -> Set<String> {
        var keep = Set<String>()
        if let manifest {
            let named = Set(manifest.entries.filter { Checksums.isDirectlyIn(folder, $0.file) }
                .map { $0.file.lastPathComponent.lowercased() })
            for (prefix, group) in groups where group.contains(where: { named.contains($0.url.lastPathComponent.lowercased()) }) {
                keep.insert(prefix)
            }
        }
        if let stem = setup?.deletingPathExtension().lastPathComponent.lowercased() {
            for prefix in groups.keys where prefix.lowercased().trimmingCharacters(in: separators) == stem {
                keep.insert(prefix)
            }
        }
        guard keep.isEmpty else { return keep }
        // No manifest or name ties a group to the setup: the main group, when it looks like a part set (several
        // files, or numbering that starts at 0 or 1).
        let size = { (group: [InstallerPart]) in group.reduce(Int64(0)) { $0 + $1.size } }
        let best = groups
            .filter { $0.value.count > 1 || $0.value.contains { $0.number <= 1 } }
            .max { a, b in
                a.value.count != b.value.count ? a.value.count < b.value.count
                    : size(a.value) != size(b.value) ? size(a.value) < size(b.value) : a.key > b.key
            }
        guard let best else { return [] }
        return [best.key]
    }

    private static let separators = CharacterSet(charactersIn: "-_. ")
}
