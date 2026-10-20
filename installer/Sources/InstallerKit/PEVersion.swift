
import Foundation

public enum PEVersion {

    public static func productName(of exe: URL) -> String? {
        string("ProductName", in: exe)
    }

    public static func string(_ key: String, in exe: URL) -> String? {
        guard let file = try? FileHandle(forReadingFrom: exe) else { return nil }
        defer { try? file.close() }
        guard let block = versionBlock(file) else { return nil }
        return value(of: key, in: block)
    }

    private static func read(_ file: FileHandle, at offset: UInt64, _ count: Int) -> Data? {
        guard count > 0, (try? file.seek(toOffset: offset)) != nil,
              let data = try? file.read(upToCount: count), data.count == count else { return nil }
        return data
    }

    // RT_VERSION, first name, first language.
    private static func versionBlock(_ file: FileHandle) -> Data? {
        guard let dos = read(file, at: 0, 64), dos.u16(0) == 0x5A4D else { return nil }
        let pe = UInt64(dos.u32(0x3C))
        guard let coff = read(file, at: pe, 24), coff.u32(0) == 0x4550 else { return nil }
        let sections = Int(coff.u16(6)), optionalSize = Int(coff.u16(20))
        guard let optional = read(file, at: pe + 24, optionalSize) else { return nil }
        let directories = optional.u16(0) == 0x20B ? 112 : 96
        guard optional.count >= directories + 24 else { return nil }
        let resourceRVA = optional.u32(directories + 16)
        guard resourceRVA != 0,
              let table = read(file, at: pe + 24 + UInt64(optionalSize), sections * 40) else { return nil }

        func offset(of rva: UInt32) -> UInt64? {
            for i in 0..<sections {
                let base = i * 40
                let va = table.u32(base + 12), size = max(table.u32(base + 8), table.u32(base + 16))
                if rva >= va && rva < va &+ size { return UInt64(table.u32(base + 20)) + UInt64(rva - va) }
            }
            return nil
        }
        guard let root = offset(of: resourceRVA) else { return nil }

        // Each level is a directory of 8-byte entries; the high bit marks a subdirectory.
        func entry(in dirOffset: UInt64, id: UInt32?) -> UInt32? {
            guard let header = read(file, at: dirOffset, 16) else { return nil }
            let count = Int(header.u16(12)) + Int(header.u16(14))
            guard count > 0, count < 4096, let entries = read(file, at: dirOffset + 16, count * 8) else { return nil }
            for i in 0..<count {
                let name = entries.u32(i * 8), target = entries.u32(i * 8 + 4)
                if id == nil || name == id { return target }
            }
            return nil
        }
        guard let type = entry(in: root, id: 16), type & 0x8000_0000 != 0,
              let name = entry(in: root + UInt64(type & 0x7FFF_FFFF), id: nil), name & 0x8000_0000 != 0,
              let lang = entry(in: root + UInt64(name & 0x7FFF_FFFF), id: nil), lang & 0x8000_0000 == 0,
              let leaf = read(file, at: root + UInt64(lang), 8),
              let start = offset(of: leaf.u32(0)) else { return nil }
        let size = Int(leaf.u32(4))
        guard size < 1 << 20 else { return nil }
        return read(file, at: start, size)
    }

    // A String entry is its UTF-16 key, padding to 4 bytes, then its UTF-16 value.
    static func value(of key: String, in block: Data) -> String? {
        let needle = Data((key + "\0").utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })
        guard let found = block.range(of: needle) else { return nil }
        var i = found.upperBound - block.startIndex
        i = (i + 3) & ~3
        var units: [UInt16] = []
        while i + 1 < block.count {
            let unit = block.u16(i)
            if unit == 0 { break }
            units.append(unit)
            i += 2
        }
        let text = String(decoding: units, as: UTF16.self).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }
}

extension Data {
    func u16(_ at: Int) -> UInt16 {
        guard at + 2 <= count else { return 0 }
        let i = startIndex + at
        return UInt16(self[i]) | UInt16(self[i + 1]) << 8
    }

    func u32(_ at: Int) -> UInt32 {
        guard at + 4 <= count else { return 0 }
        return UInt32(u16(at)) | UInt32(u16(at + 2)) << 16
    }
}
