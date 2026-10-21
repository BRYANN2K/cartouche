// Reads only the import directory of PE32/PE32+ files: a handful of small reads, never the whole file.

import Foundation

public enum PEImports {

    public struct Info: Sendable, Equatable {
        // Imported module names, lowercased, without the ".dll" suffix.
        public var dlls: [String] = []
        // A .NET assembly: the CLI header is present or mscoree.dll is imported. Wine Mono runs .NET 4.x.
        public var isDotNet = false
    }

    public static func scan(_ exe: URL) -> Info? {
        guard let file = try? FileHandle(forReadingFrom: exe) else { return nil }
        defer { try? file.close() }
        guard let dos = read(file, at: 0, 64), dos.u16(0) == 0x5A4D else { return nil }
        let pe = UInt64(dos.u32(0x3C))
        guard let coff = read(file, at: pe, 24), coff.u32(0) == 0x4550 else { return nil }
        let sectionCount = Int(coff.u16(6)), optionalSize = Int(coff.u16(20))
        guard let optional = read(file, at: pe + 24, optionalSize) else { return nil }
        let directories: Int
        switch optional.u16(0) {
        case 0x10B: directories = 96
        case 0x20B: directories = 112
        default: return nil
        }
        guard optional.count >= directories + 4 else { return nil }
        let directoryCount = Int(optional.u32(directories - 4))
        guard let table = read(file, at: pe + 24 + UInt64(optionalSize), sectionCount * 40) else { return nil }

        func offset(of rva: UInt32) -> UInt64? {
            for i in 0..<sectionCount {
                let base = i * 40
                let va = table.u32(base + 12), size = max(table.u32(base + 8), table.u32(base + 16))
                if rva >= va && rva < va &+ size { return UInt64(table.u32(base + 20)) + UInt64(rva - va) }
            }
            return nil
        }

        var info = Info()
        info.isDotNet = directoryCount > 14 && optional.u32(directories + 14 * 8) != 0
        let importRVA = directoryCount > 1 ? optional.u32(directories + 8) : 0
        guard importRVA != 0, var at = offset(of: importRVA) else { return info }

        // 20-byte descriptors ending in an all-zero one; names are read one by one.
        var descriptors = 0
        var done = false
        while !done, descriptors < 256, let block = read(file, at: at, 1000) {
            let complete = block.count - block.count % 20
            for i in stride(from: 0, to: complete, by: 20) {
                let nameRVA = block.u32(i + 12)
                if block.u32(i) == 0, nameRVA == 0, block.u32(i + 16) == 0 { done = true; break }
                descriptors += 1
                guard let nameAt = offset(of: nameRVA), let bytes = read(file, at: nameAt, 64) else { continue }
                var dll = String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self).lowercased()
                if dll.hasSuffix(".dll") { dll = String(dll.dropLast(4)) }
                if !dll.isEmpty { info.dlls.append(dll) }
                if dll == "mscoree" { info.isDotNet = true }
            }
            at += UInt64(complete)
        }
        return info
    }

    private static func read(_ file: FileHandle, at offset: UInt64, _ count: Int) -> Data? {
        guard count > 0, (try? file.seek(toOffset: offset)) != nil,
              let data = try? file.read(upToCount: count), !data.isEmpty else { return nil }
        return data
    }
}
