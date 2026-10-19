import Foundation

// One game of the libretro database, as its .rdb file holds it
public struct DatabaseEntry: Sendable, Equatable {
    // No-Intro or Redump name: "Super Metroid (Japan, USA) (En,Ja)"
    public var name: String
    public var romName: String?
    public var crc: UInt32?
    public var md5: String?
    public var sha1: String?
    // The disc's or cartridge's product code: "SCUS-94900"
    public var serial: String?
    public var size: UInt64?

    public init(name: String, romName: String? = nil, crc: UInt32? = nil, md5: String? = nil, sha1: String? = nil,
                serial: String? = nil, size: UInt64? = nil) {
        self.name = name
        self.romName = romName
        self.crc = crc
        self.md5 = md5
        self.sha1 = sha1
        self.serial = serial
        self.size = size
    }

    // TOSEC hacks, translations and bad dumps carry flags in brackets
    var isFlagged: Bool { name.contains("[") }
}

// RetroArch's libretro-db file: "RARCHDB", the metadata offset, then one
// MessagePack map per game up to a nil
public enum RDB {

    public enum Problem: Error, Equatable {
        case notADatabase
        case damaged(at: Int)
    }

    public static func read(_ url: URL) throws -> [DatabaseEntry] {
        try parse(Data(contentsOf: url, options: .mappedIfSafe))
    }

    public static func parse(_ data: Data) throws -> [DatabaseEntry] {
        guard data.count >= 16, data.prefix(7) == Data("RARCHDB".utf8) else { throw Problem.notADatabase }
        return try data.withUnsafeBytes { raw in
            var reader = Reader(bytes: raw, at: 16)
            var entries: [DatabaseEntry] = []
            while reader.at < raw.count {
                guard case .map(let fields) = try reader.value() else { break }
                var entry = DatabaseEntry(name: "")
                for (key, value) in fields {
                    switch (key, value) {
                    case ("name", .string(let s)): entry.name = s
                    case ("rom_name", .string(let s)): entry.romName = s
                    case ("crc", .bytes(let b)) where b.count == 4:
                        entry.crc = b.reduce(0) { $0 << 8 | UInt32($1) }
                    case ("md5", .bytes(let b)): entry.md5 = hex(b)
                    case ("sha1", .bytes(let b)): entry.sha1 = hex(b)
                    case ("serial", .bytes(let b)): entry.serial = String(decoding: b, as: UTF8.self)
                    case ("serial", .string(let s)): entry.serial = s
                    case ("size", .unsigned(let n)): entry.size = n
                    default: break
                    }
                }
                if !entry.name.isEmpty { entries.append(entry) }
            }
            return entries
        }
    }

    static func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

    enum Value {
        case `nil`, bool(Bool), unsigned(UInt64), signed(Int64), string(String), bytes([UInt8])
        case array([Value]), map([(String, Value)])
    }

    // The MessagePack that libretro-db writes, read without copying the file
    struct Reader {
        let bytes: UnsafeRawBufferPointer
        var at: Int

        mutating func byte() throws -> UInt8 {
            guard at < bytes.count else { throw Problem.damaged(at: at) }
            defer { at += 1 }
            return bytes[at]
        }

        mutating func number(_ width: Int) throws -> UInt64 {
            guard at + width <= bytes.count else { throw Problem.damaged(at: at) }
            var n: UInt64 = 0
            for i in 0..<width { n = n << 8 | UInt64(bytes[at + i]) }
            at += width
            return n
        }

        mutating func raw(_ count: Int) throws -> [UInt8] {
            guard count >= 0, at + count <= bytes.count else { throw Problem.damaged(at: at) }
            defer { at += count }
            return Array(bytes[at..<(at + count)])
        }

        mutating func value() throws -> Value {
            let t = try byte()
            switch t {
            case 0x00...0x7F: return .unsigned(UInt64(t))
            case 0x80...0x8F: return try map(Int(t & 0x0F))
            case 0x90...0x9F: return try array(Int(t & 0x0F))
            case 0xA0...0xBF: return .string(String(decoding: try raw(Int(t & 0x1F)), as: UTF8.self))
            case 0xC0: return .nil
            case 0xC2: return .bool(false)
            case 0xC3: return .bool(true)
            case 0xC4: return .bytes(try raw(Int(try number(1))))
            case 0xC5: return .bytes(try raw(Int(try number(2))))
            case 0xC6: return .bytes(try raw(Int(try number(4))))
            case 0xCC: return .unsigned(try number(1))
            case 0xCD: return .unsigned(try number(2))
            case 0xCE: return .unsigned(try number(4))
            case 0xCF: return .unsigned(try number(8))
            case 0xD0: return .signed(Int64(Int8(truncatingIfNeeded: try number(1))))
            case 0xD1: return .signed(Int64(Int16(truncatingIfNeeded: try number(2))))
            case 0xD2: return .signed(Int64(Int32(truncatingIfNeeded: try number(4))))
            case 0xD3: return .signed(Int64(bitPattern: try number(8)))
            case 0xD9: return .string(String(decoding: try raw(Int(try number(1))), as: UTF8.self))
            case 0xDA: return .string(String(decoding: try raw(Int(try number(2))), as: UTF8.self))
            case 0xDB: return .string(String(decoding: try raw(Int(try number(4))), as: UTF8.self))
            case 0xDC: return try array(Int(try number(2)))
            case 0xDD: return try array(Int(try number(4)))
            case 0xDE: return try map(Int(try number(2)))
            case 0xDF: return try map(Int(try number(4)))
            case 0xE0...0xFF: return .signed(Int64(Int8(bitPattern: t)))
            default: throw Problem.damaged(at: at - 1)
            }
        }

        private mutating func array(_ count: Int) throws -> Value {
            var items: [Value] = []
            for _ in 0..<count { items.append(try value()) }
            return .array(items)
        }

        private mutating func map(_ count: Int) throws -> Value {
            var fields: [(String, Value)] = []
            for _ in 0..<count {
                guard case .string(let key) = try value() else { throw Problem.damaged(at: at) }
                fields.append((key, try value()))
            }
            return .map(fields)
        }
    }

    // Writes entries the way libretro-db does, for test fixtures and tools
    public static func write(_ entries: [DatabaseEntry]) -> Data {
        var out = Data("RARCHDB".utf8) + Data([0])
        out += Data(repeating: 0, count: 8)
        func string(_ s: String) {
            let b = Array(s.utf8)
            if b.count < 32 { out.append(0xA0 | UInt8(b.count)) } else { out.append(0xD9); out.append(UInt8(b.count)) }
            out += b
        }
        func bytes(_ b: [UInt8]) { out.append(0xC4); out.append(UInt8(b.count)); out += b }
        func unhex(_ s: String) -> [UInt8] {
            stride(from: 0, to: s.count, by: 2).compactMap { i in
                let start = s.index(s.startIndex, offsetBy: i)
                return UInt8(s[start..<s.index(start, offsetBy: 2)], radix: 16)
            }
        }
        for entry in entries {
            var fields: [(String, () -> Void)] = [("name", { string(entry.name) })]
            if let rom = entry.romName { fields.append(("rom_name", { string(rom) })) }
            if let size = entry.size { fields.append(("size", { out.append(0xCF); out += withUnsafeBytes(of: size.bigEndian) { Data($0) } })) }
            if let crc = entry.crc { fields.append(("crc", { bytes(withUnsafeBytes(of: crc.bigEndian) { Array($0) }) })) }
            if let md5 = entry.md5 { fields.append(("md5", { bytes(unhex(md5)) })) }
            if let sha1 = entry.sha1 { fields.append(("sha1", { bytes(unhex(sha1)) })) }
            if let serial = entry.serial { fields.append(("serial", { bytes(Array(serial.utf8)) })) }
            out.append(0x80 | UInt8(fields.count))
            for (key, write) in fields {
                string(key)
                write()
            }
        }
        out.append(0xC0)
        let offset = UInt64(out.count)
        out.replaceSubrange(8..<16, with: withUnsafeBytes(of: offset.bigEndian) { Data($0) })
        out.append(0x81)
        string("count")
        out.append(0xCF)
        out += withUnsafeBytes(of: UInt64(entries.count).bigEndian) { Data($0) }
        return out
    }
}
