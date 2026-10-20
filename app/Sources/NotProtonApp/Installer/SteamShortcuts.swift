// Show in Steam: a non-Steam shortcut in each account's shortcuts.vdf that
// starts the game's launch script. Steam keeps the file in memory and writes it
// back, so it is only changed while Steam is closed.

import Foundation

struct SteamShortcuts: Sendable {

    enum Outcome: Sendable, Equatable {
        case added
        case alreadyThere
        case steamRunning
        case noAccount
        case failed(String)
    }

    var userdata: URL = SupportPaths.Steam.userData.appending(path: "userdata")
    var steamIsRunning: @Sendable () -> Bool = { SteamBundle.isRunning }

    func add(name: String, launcher: URL, startDir: URL) -> Outcome {
        guard !steamIsRunning() else { return .steamRunning }
        let fm = FileManager.default
        let accounts = ((try? fm.contentsOfDirectory(at: userdata, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
            .filter { Int($0.lastPathComponent).map { $0 > 0 } ?? false }
            .filter { fm.fileExists(atPath: $0.appending(path: "config").path(percentEncoded: false)) }
        guard !accounts.isEmpty else { return .noAccount }

        let exe = "\"" + launcher.path(percentEncoded: false) + "\""
        var writes: [(file: URL, root: [(String, BinaryVDF)])] = []
        for account in accounts.sorted(by: { $0.path < $1.path }) {
            let file = account.appending(path: "config/shortcuts.vdf")
            var root: [(String, BinaryVDF)] = [("shortcuts", .map([]))]
            if let data = try? Data(contentsOf: file) {
                guard let parsed = BinaryVDF.parse(data) else { return .failed(String(localized: "Steam's shortcuts file could not be read.")) }
                root = parsed
            }
            guard let index = root.firstIndex(where: { $0.0.lowercased() == "shortcuts" }), case .map(var entries) = root[index].1 else {
                return .failed(String(localized: "Steam's shortcuts file could not be read."))
            }
            if entries.contains(where: { $0.1.string("exe") == exe }) { continue }
            // The first numeric key no entry uses; keys need not be contiguous.
            var key = entries.count
            while entries.contains(where: { $0.0 == String(key) }) { key += 1 }
            entries.append((String(key), BinaryVDF.shortcut(name: name, exe: exe, startDir: startDir)))
            root[index].1 = .map(entries)
            writes.append((file, root))
        }
        guard !writes.isEmpty else { return .alreadyThere }
        for (file, root) in writes {
            // A copy next to Steam's file, so a bad write never costs the shortcuts.
            if fm.fileExists(atPath: file.path(percentEncoded: false)) {
                try? fm.copyItem(at: file, to: file.appendingPathExtension("cartouche"))
            }
            do {
                try atomicReplace(file, with: BinaryVDF.serialize(root), step: String(localized: "Add the game to Steam"))
            } catch {
                return .failed(error.localizedDescription)
            }
        }
        return .added
    }
}

// Binary KeyValues: a type byte, a key, a value; 0x08 closes a map.
indirect enum BinaryVDF: Equatable, Sendable {
    case map([(String, BinaryVDF)])
    case string(String)
    case int(UInt32)
    // Types this file does not need, kept byte for byte.
    case raw(UInt8, [UInt8])

    static func == (a: BinaryVDF, b: BinaryVDF) -> Bool {
        switch (a, b) {
        case let (.map(x), .map(y)): x.count == y.count && zip(x, y).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        case let (.string(x), .string(y)): x == y
        case let (.int(x), .int(y)): x == y
        case let (.raw(t, x), .raw(u, y)): t == u && x == y
        default: false
        }
    }

    func string(_ key: String) -> String? {
        guard case .map(let entries) = self,
              case .string(let value)? = entries.first(where: { $0.0.lowercased() == key })?.1 else { return nil }
        return value
    }

    static func parse(_ data: Data) -> [(String, BinaryVDF)]? {
        let bytes = [UInt8](data)
        var at = 0
        func cString() -> String? {
            guard let end = bytes[at...].firstIndex(of: 0) else { return nil }
            defer { at = end + 1 }
            return String(decoding: bytes[at..<end], as: UTF8.self)
        }
        func take(_ n: Int) -> [UInt8]? {
            guard bytes.count - at >= n else { return nil }
            defer { at += n }
            return Array(bytes[at..<at + n])
        }
        func map(depth: Int) -> [(String, BinaryVDF)]? {
            guard depth < 32 else { return nil }
            var entries: [(String, BinaryVDF)] = []
            while at < bytes.count {
                let type = bytes[at]
                at += 1
                if type == 0x08 { return entries }
                guard let key = cString() else { return nil }
                switch type {
                case 0x00: guard let sub = map(depth: depth + 1) else { return nil }; entries.append((key, .map(sub)))
                case 0x01: guard let s = cString() else { return nil }; entries.append((key, .string(s)))
                case 0x02: guard let b = take(4) else { return nil }
                    entries.append((key, .int(b.reversed().reduce(0) { $0 << 8 | UInt32($1) })))
                case 0x03, 0x04, 0x06: guard let b = take(4) else { return nil }; entries.append((key, .raw(type, b)))
                case 0x07, 0x0a: guard let b = take(8) else { return nil }; entries.append((key, .raw(type, b)))
                default: return nil
                }
            }
            return depth == 0 ? entries : nil
        }
        guard let root = map(depth: 0) else { return nil }
        // The file ends with the root's own 0x08.
        return root
    }

    static func serialize(_ root: [(String, BinaryVDF)]) -> Data {
        var out: [UInt8] = []
        func write(_ entries: [(String, BinaryVDF)]) {
            for (key, value) in entries {
                switch value {
                case .map(let sub): out.append(0x00); out += Array(key.utf8) + [0]; write(sub); out.append(0x08)
                case .string(let s): out.append(0x01); out += Array(key.utf8) + [0] + Array(s.utf8) + [0]
                case .int(let v): out.append(0x02); out += Array(key.utf8) + [0] + withUnsafeBytes(of: v.littleEndian, Array.init)
                case .raw(let type, let bytes): out.append(type); out += Array(key.utf8) + [0] + bytes
                }
            }
        }
        write(root)
        out.append(0x08)
        return Data(out)
    }

    // Steam's own fields for a shortcut. The App ID is the CRC Steam derives from exe and name.
    static func shortcut(name: String, exe: String, startDir: URL) -> BinaryVDF {
        .map([
            ("appid", .int(crc32(Array((exe + name).utf8)) | 0x8000_0000)),
            ("AppName", .string(name)),
            ("Exe", .string(exe)),
            ("StartDir", .string("\"" + startDir.path(percentEncoded: false) + "\"")),
            ("icon", .string("")),
            ("ShortcutPath", .string("")),
            ("LaunchOptions", .string("")),
            ("IsHidden", .int(0)),
            ("AllowDesktopConfig", .int(1)),
            ("AllowOverlay", .int(1)),
            ("OpenVR", .int(0)),
            ("Devkit", .int(0)),
            ("DevkitGameID", .string("")),
            ("DevkitOverrideAppID", .int(0)),
            ("LastPlayTime", .int(0)),
            ("FlatpakAppID", .string("")),
            ("tags", .map([])),
        ])
    }

    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 != 0 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        }
        return ~crc
    }
}
