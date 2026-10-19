// Steam's binary appinfo.vdf format, shared by the app (SteamAppInfo) and the
// appinfo helper the run script shells out to (helpers/appinfo/main.swift,
// compiled with this file by the Makefile).

import Foundation

enum AppInfoVDF {

    enum ParseError: Error, Equatable {
        case truncated, unknownMagic(UInt32), unknownType(UInt8), badStringIndex(UInt32), tooDeep
    }

    indirect enum Value: Equatable {
        case string(String)
        case number(Int64)
        case section([String: Value])
    }

    struct Cursor {
        let b: [UInt8]
        var p: Int
        let end: Int

        init(b: [UInt8], p: Int, end: Int? = nil) {
            self.b = b
            self.p = p
            self.end = end ?? b.count
        }

        mutating func u8() throws -> UInt8 {
            guard p < end else { throw ParseError.truncated }
            defer { p += 1 }
            return b[p]
        }

        mutating func u32() throws -> UInt32 {
            guard p + 4 <= end else { throw ParseError.truncated }
            defer { p += 4 }
            return UInt32(b[p]) | UInt32(b[p + 1]) << 8
                | UInt32(b[p + 2]) << 16 | UInt32(b[p + 3]) << 24
        }

        mutating func u64() throws -> UInt64 {
            guard p + 8 <= end else { throw ParseError.truncated }
            var v: UInt64 = 0
            for i in 0..<8 { v |= UInt64(b[p + i]) << (8 * UInt64(i)) }
            p += 8
            return v
        }

        // Values and, before the string table existed, keys are NUL terminated.
        mutating func cstring() throws -> String {
            var stop = p
            while stop < end && b[stop] != 0 { stop += 1 }
            guard stop < end else { throw ParseError.truncated }
            defer { p = stop + 1 }
            return String(decoding: b[p..<stop], as: UTF8.self)
        }

        // A wide string ends at a NUL pair, not a single NUL.
        mutating func wcstring() throws -> String {
            var stop = p
            while stop + 1 < end && !(b[stop] == 0 && b[stop + 1] == 0) { stop += 2 }
            guard stop + 1 < end else { throw ParseError.truncated }
            var units: [UInt16] = []
            var i = p
            while i < stop {
                units.append(UInt16(b[i]) | UInt16(b[i + 1]) << 8)
                i += 2
            }
            p = stop + 2
            return String(decoding: units, as: UTF16.self)
        }

        mutating func skip(_ n: Int) throws {
            guard p + n <= end else { throw ParseError.truncated }
            p += n
        }
    }

    // v29 moved every key into one table at the end of the file and left an index
    // in its place, so the table has to be read before any app can be parsed.
    static func readStringTable(_ b: [UInt8], at offset: Int) throws -> [String] {
        var c = Cursor(b: b, p: offset)
        let count = try c.u32()
        var out: [String] = []
        out.reserveCapacity(Int(count))
        for _ in 0..<count { out.append(try c.cstring()) }
        return out
    }

    static func readSection(_ c: inout Cursor, _ table: [String]?, depth: Int = 0) throws -> [String: Value] {
        guard depth < 64 else { throw ParseError.tooDeep }
        var out: [String: Value] = [:]
        while true {
            let type = try c.u8()
            // 0x0b is the alternate section terminator the format also allows.
            if type == 0x08 || type == 0x0b { return out }
            let key: String
            if let table = table {
                let i = try c.u32()
                guard Int(i) < table.count else { throw ParseError.badStringIndex(i) }
                key = table[Int(i)]
            } else {
                key = try c.cstring()
            }
            switch type {
            // Handles every type the format defines. An unused-but-legal type inside
            // an app entry would otherwise drop the whole entry and its name.
            case 0x00: out[key] = .section(try readSection(&c, table, depth: depth + 1))
            case 0x01: out[key] = .string(try c.cstring())
            case 0x02: out[key] = .number(Int64(Int32(bitPattern: try c.u32())))
            case 0x03: try c.skip(4)
            case 0x04: try c.skip(4)
            case 0x05: out[key] = .string(try c.wcstring())
            case 0x06: try c.skip(4)
            case 0x07: out[key] = .number(Int64(bitPattern: try c.u64()))
            case 0x0a: out[key] = .number(Int64(bitPattern: try c.u64()))
            default: throw ParseError.unknownType(type)
            }
        }
    }

    // Returns false when the list runs out before the zero appid that ends it.
    static func forEachApp(_ b: [UInt8], _ visit: (UInt32, () throws -> [String: Value]) throws -> Bool) throws -> Bool {
        var head = Cursor(b: b, p: 0)
        let magic = try head.u32()
        _ = try head.u32()

        var table: [String]? = nil
        var pos: Int
        var entriesEnd = b.count
        // The sha1 of the entry's own binary vdf arrived in v28, which moves the
        // start of the key data 20 bytes further into every app entry.
        var entryHeader = 60
        switch magic {
        case 0x0756_4429:
            let offset = try head.u64()
            guard offset >= 16, offset < UInt64(b.count) else { throw ParseError.truncated }
            table = try readStringTable(b, at: Int(offset))
            entriesEnd = Int(offset)
            pos = 16
        case 0x0756_4428:
            pos = 8
        case 0x0756_4427:
            pos = 8
            entryHeader = 40
        default:
            throw ParseError.unknownMagic(magic)
        }

        while pos + 4 <= entriesEnd {
            var e = Cursor(b: b, p: pos, end: entriesEnd)
            let id = try e.u32()
            if id == 0 { return true }
            let size = Int(try e.u32())
            guard size >= entryHeader, size <= entriesEnd - pos - 8 else { throw ParseError.truncated }
            let entryEnd = pos + 8 + size
            let start = pos + 8 + entryHeader
            let keys = { () throws -> [String: Value] in
                var kv = Cursor(b: b, p: start, end: entryEnd)
                let root = try readSection(&kv, table)
                // Each entry wraps its keys in one "appinfo" section.
                if case .section(let inner)? = root["appinfo"] { return inner }
                return root
            }
            if try !visit(id, keys) { return true }
            pos = entryEnd
        }
        return false
    }
}
