// After the install: which exe starts the game. Reads the .lnk shortcuts and
// the Uninstall registry key the installer wrote into the prefix, and the exes
// in the install folder, then ranks them with ExeDetector.

import Foundation

// [MS-SHLLINK]: header, optional ID list, LinkInfo with the local path, then strings.
public enum ShellLink {

    public struct Info: Sendable, Equatable {
        public var target: String?
        public var workingDirectory: String?
        public var arguments: String?
    }

    public static func parse(_ data: Data) -> Info? {
        guard data.count >= 0x4C, data.u32(0) == 0x4C else { return nil }
        let flags = data.u32(0x14)
        let unicode = flags & 0x80 != 0
        var at = 0x4C
        if flags & 0x1 != 0 { at += 2 + Int(data.u16(at)) }
        var info = Info()
        if flags & 0x2 != 0 {
            let size = Int(data.u32(at)), header = Int(data.u32(at + 4)), linkFlags = data.u32(at + 8)
            if linkFlags & 0x1 != 0 {
                if header >= 0x24, data.u32(at + 0x1C) != 0 {
                    info.target = utf16z(data, at + Int(data.u32(at + 0x1C)))
                        .map { $0 + (utf16z(data, at + Int(data.u32(at + 0x20))) ?? "") }
                } else {
                    info.target = cstring(data, at + Int(data.u32(at + 0x10)))
                        .map { $0 + (cstring(data, at + Int(data.u32(at + 0x18))) ?? "") }
                }
            }
            at += size
        }
        // NAME, RELATIVE_PATH, WORKING_DIR, ARGUMENTS, ICON_LOCATION, each when its flag is set.
        var strings: [Int: String] = [:]
        for (bit, slot) in [(UInt32(0x4), 0), (0x8, 1), (0x10, 2), (0x20, 3), (0x40, 4)] where flags & bit != 0 {
            let count = Int(data.u16(at)); at += 2
            let length = unicode ? count * 2 : count
            guard at + length <= data.count else { break }
            let bytes = data.subdata(in: data.startIndex + at..<data.startIndex + at + length)
            strings[slot] = unicode ? String(data: bytes, encoding: .utf16LittleEndian) : String(decoding: bytes, as: UTF8.self)
            at += length
        }
        info.workingDirectory = strings[2]
        info.arguments = strings[3]
        if info.target == nil, let relative = strings[1], let dir = strings[2] {
            if let name = relative.split(separator: "\\").last {
                info.target = dir.hasSuffix("\\") ? dir + name : dir + "\\" + name
            }
        }
        return info.target == nil && info.workingDirectory == nil ? nil : info
    }

    private static func cstring(_ data: Data, _ offset: Int) -> String? {
        guard offset > 0, offset < data.count else { return nil }
        let bytes = data[(data.startIndex + offset)...].prefix { $0 != 0 }
        return bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self)
    }

    private static func utf16z(_ data: Data, _ offset: Int) -> String? {
        guard offset > 0, offset < data.count else { return nil }
        var units: [UInt16] = []
        var i = offset
        while i + 1 < data.count, data.u16(i) != 0 { units.append(data.u16(i)); i += 2 }
        return units.isEmpty ? nil : String(decoding: units, as: UTF16.self)
    }

    // Start Menu and Desktop shortcuts of every Wine user, and the shared ones.
    public static func targets(in prefix: URL) -> [String] {
        let roots = ["drive_c/users", "drive_c/ProgramData/Microsoft/Windows/Start Menu"].map { prefix.appending(path: $0) }
        var targets: [String] = []
        for root in roots {
            guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walk where url.pathExtension.lowercased() == "lnk" {
                if let data = try? Data(contentsOf: url), let target = parse(data)?.target { targets.append(target) }
            }
        }
        return targets
    }
}

public struct UninstallEntry: Sendable, Equatable {
    public let key: String
    public var displayName: String?
    public var displayIcon: String?
    public var installLocation: String?
}

// Wine's system.reg and user.reg are text: [key] lines, then "name"="value".
public enum WineRegistry {

    public static func uninstallEntries(prefix: URL) -> [UninstallEntry] {
        ["system.reg", "user.reg"].flatMap { name -> [UninstallEntry] in
            guard let text = try? String(contentsOf: prefix.appending(path: name), encoding: .utf8) else { return [] }
            return uninstallEntries(in: text)
        }
    }

    public static func uninstallEntries(in text: String) -> [UninstallEntry] {
        var entries: [UninstallEntry] = []
        var current: UninstallEntry?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                if let current { entries.append(current) }
                current = nil
                let key = unescape(String(line.dropFirst().prefix { $0 != "]" }))
                if key.lowercased().contains(#"\microsoft\windows\currentversion\uninstall\"#) {
                    current = UninstallEntry(key: key)
                }
                continue
            }
            guard current != nil, let m = try? /^"([^"]+)"=(?:str\(\d\):)?"(.*)"$/.wholeMatch(in: line) else { continue }
            let value = unescape(String(m.2))
            switch String(m.1).lowercased() {
            case "displayname": current?.displayName = value
            case "displayicon": current?.displayIcon = value
            case "installlocation": current?.installLocation = value
            default: break
            }
        }
        if let current { entries.append(current) }
        return entries
    }

    // \\ and \" and \xNNNN, as Wine writes them; keys double their backslashes too.
    static func unescape(_ s: String) -> String {
        var out = ""
        var it = Array(s)[...]
        while let c = it.popFirst() {
            guard c == "\\", let next = it.first else { out.append(c); continue }
            it.removeFirst()
            if next == "x" {
                let hex = it.prefix { $0.isHexDigit }.prefix(4)
                it.removeFirst(hex.count)
                if let code = UInt32(String(hex), radix: 16), let scalar = Unicode.Scalar(code) { out.unicodeScalars.append(scalar) }
            } else {
                out.append(next == "n" ? "\n" : next)
            }
        }
        return out
    }

    // "C:\Games\X\game.exe",0 → C:\Games\X\game.exe
    public static func iconPath(_ value: String) -> String {
        var v = value.trimmingCharacters(in: .whitespaces)
        if let comma = v.range(of: ",", options: .backwards), v[comma.upperBound...].allSatisfy({ $0.isNumber || $0 == "-" }) {
            v = String(v[..<comma.lowerBound])
        }
        return v.trimmingCharacters(in: .init(charactersIn: "\" "))
    }
}

extension ExeDetector {

    public struct Scan: Sendable, Equatable {
        // Where the game ended up: the folder asked for, or the one the installer registered.
        public let installFolder: URL
        public let candidates: [Candidate]
    }

    // primary: a GOG play task's exe.
    public static func scan(installFolder expected: URL, prefix: URL, primary: URL? = nil) -> Scan {
        let fm = FileManager.default
        let uninstall = WineRegistry.uninstallEntries(prefix: prefix)
        var folder = expected
        if !fm.fileExists(atPath: expected.path(percentEncoded: false)),
           let registered = uninstall.compactMap({ $0.installLocation }).compactMap({ WinePath.unix($0, prefix: prefix) })
            .first(where: { fm.fileExists(atPath: $0.path(percentEncoded: false)) }) {
            folder = registered
        }

        var exes: [(path: String, size: Int64)] = []
        if let walk = fm.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let url as URL in walk where url.pathExtension.lowercased() == "exe" {
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map(Int64.init) ?? 0
                exes.append((url.standardizedFileURL.path(percentEncoded: false), size))
            }
        }
        let unix = { (windows: String) in WinePath.unix(windows, prefix: prefix)?.standardizedFileURL.path(percentEncoded: false) }
        let shortcuts = ShellLink.targets(in: prefix).compactMap(unix)
        let icon = uninstall.compactMap(\.displayIcon).map(WineRegistry.iconPath).compactMap(unix)
            .first { path in exes.contains { $0.path.caseInsensitiveCompare(path) == .orderedSame } }
        let primaryPath = primary.map { $0.standardizedFileURL.path(percentEncoded: false) }
        return Scan(installFolder: folder, candidates: rank(exes: exes, shortcuts: shortcuts, uninstallIcon: icon, primary: primaryPath))
    }
}
