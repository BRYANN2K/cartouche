// Which Steam games have a macOS build next to the Windows one, from Steam's binary
// appinfo.vdf cache (common/oslist). The same reading as helpers/appinfo.swift, which
// the run script uses; this one runs inside the app.

import Foundation

enum SteamAppInfo {

    static var cache: URL { SupportPaths.Steam.userData.appending(path: "appcache/appinfo.vdf") }

    struct Platforms: Equatable, Sendable {
        var mac: Set<Int> = []
        var windows: Set<Int> = []

        // A choice between the Mac and the Windows version exists for these
        var both: Set<Int> { mac.intersection(windows) }
    }

    enum Failure: Error, Equatable {
        case truncated, unknownMagic(UInt32), unknownType(UInt8), badStringIndex(UInt32), tooDeep
    }

    static func platforms(at url: URL = cache) -> Platforms? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? platforms(Array(data))
    }

    // Steam treats an app without an oslist as Windows only
    static func platforms(_ b: [UInt8]) throws -> Platforms {
        var out = Platforms()
        try forEachApp(b) { id, common in
            guard let common else { return }
            guard let oslist = common["oslist"] else {
                out.windows.insert(Int(id))
                return
            }
            let systems = oslist.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if systems.contains("macos") { out.mac.insert(Int(id)) }
            if systems.contains("windows") { out.windows.insert(Int(id)) }
        }
        return out
    }

    private struct Cursor {
        let b: [UInt8]
        var p: Int
        let end: Int

        mutating func u8() throws -> UInt8 {
            guard p < end else { throw Failure.truncated }
            defer { p += 1 }
            return b[p]
        }

        mutating func u32() throws -> UInt32 {
            guard p + 4 <= end else { throw Failure.truncated }
            defer { p += 4 }
            return UInt32(b[p]) | UInt32(b[p + 1]) << 8 | UInt32(b[p + 2]) << 16 | UInt32(b[p + 3]) << 24
        }

        mutating func u64() throws -> UInt64 {
            guard p + 8 <= end else { throw Failure.truncated }
            var v: UInt64 = 0
            for i in 0..<8 { v |= UInt64(b[p + i]) << (8 * UInt64(i)) }
            p += 8
            return v
        }

        mutating func cstring() throws -> String {
            var stop = p
            while stop < end && b[stop] != 0 { stop += 1 }
            guard stop < end else { throw Failure.truncated }
            defer { p = stop + 1 }
            return String(decoding: b[p..<stop], as: UTF8.self)
        }

        mutating func skip(_ n: Int) throws {
            guard p + n <= end else { throw Failure.truncated }
            p += n
        }

        // Skips a wide string, which ends at a NUL pair
        mutating func skipWide() throws {
            while p + 1 < end && !(b[p] == 0 && b[p + 1] == 0) { p += 2 }
            guard p + 1 < end else { throw Failure.truncated }
            p += 2
        }
    }

    private indirect enum Node {
        case string(String)
        case section([String: Node])

        var section: [String: Node]? {
            if case .section(let map) = self { return map }
            return nil
        }
    }

    // Strings and sections; numbers are skipped, nothing here needs them
    private static func section(_ c: inout Cursor, _ table: [String]?, depth: Int = 0) throws -> [String: Node] {
        guard depth < 64 else { throw Failure.tooDeep }
        var out: [String: Node] = [:]
        while true {
            let type = try c.u8()
            // 0x0b is the other section end the format allows
            if type == 0x08 || type == 0x0b { return out }
            let key: String
            if let table {
                let i = try c.u32()
                guard Int(i) < table.count else { throw Failure.badStringIndex(i) }
                key = table[Int(i)]
            } else {
                key = try c.cstring()
            }
            switch type {
            case 0x00: out[key] = .section(try section(&c, table, depth: depth + 1))
            case 0x01: out[key] = .string(try c.cstring())
            case 0x02, 0x03, 0x04, 0x06: try c.skip(4)
            case 0x05: try c.skipWide()
            case 0x07, 0x0a: try c.skip(8)
            default: throw Failure.unknownType(type)
            }
        }
    }

    private static func forEachApp(_ b: [UInt8], _ visit: (UInt32, [String: String]?) throws -> Void) throws {
        var head = Cursor(b: b, p: 0, end: b.count)
        let magic = try head.u32()
        _ = try head.u32()
        var table: [String]?
        var pos = 8
        var entriesEnd = b.count
        // v28 added a SHA-1 of the entry's binary data, 20 more header bytes
        var entryHeader = 60
        switch magic {
        case 0x0756_4429:
            let offset = try head.u64()
            guard offset >= 16, offset < UInt64(b.count) else { throw Failure.truncated }
            var t = Cursor(b: b, p: Int(offset), end: b.count)
            let count = try t.u32()
            var strings: [String] = []
            for _ in 0..<count { strings.append(try t.cstring()) }
            table = strings
            entriesEnd = Int(offset)
            pos = 16
        case 0x0756_4428:
            break
        case 0x0756_4427:
            entryHeader = 40
        default:
            throw Failure.unknownMagic(magic)
        }
        while pos + 4 <= entriesEnd {
            var e = Cursor(b: b, p: pos, end: entriesEnd)
            let id = try e.u32()
            if id == 0 { return }
            let size = Int(try e.u32())
            guard size >= entryHeader, size <= entriesEnd - pos - 8 else { throw Failure.truncated }
            var kv = Cursor(b: b, p: pos + 8 + entryHeader, end: pos + 8 + size)
            let root = try section(&kv, table)
            // Each entry wraps its keys in one appinfo section
            let keys = root["appinfo"]?.section ?? root
            var common: [String: String]?
            if let map = keys["common"]?.section {
                common = map.compactMapValues { if case .string(let v) = $0 { v } else { nil } }
            }
            try visit(id, common)
            pos += 8 + size
        }
        throw Failure.truncated
    }
}
