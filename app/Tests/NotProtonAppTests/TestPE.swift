import Foundation

// The smallest PE file that still carries a real import directory: one section holding the
// descriptors and the DLL names, nothing else.
enum TestPE {
    static func build(bits: Int = 64, imports: [String], dotNet: Bool = false) -> Data {
        let pe = 0x80
        let optSize = bits == 64 ? 0xF0 : 0xE0
        let sectionRVA: UInt32 = 0x1000, sectionOffset = 0x200
        var descriptors = Data(), names = Data()
        let tableSize = (imports.count + 1) * 20
        for name in imports {
            descriptors.append(Data(count: 12))
            descriptors.append(le32(sectionRVA + UInt32(tableSize + names.count)))
            descriptors.append(Data(count: 4))
            names.append(contentsOf: name.utf8)
            names.append(0)
        }
        descriptors.append(Data(count: 20))
        let content = descriptors + names

        var data = Data(count: sectionOffset)
        data[0] = 0x4D; data[1] = 0x5A
        data.set(0x3C, UInt32(pe))
        data.set(pe, UInt32(0x4550))
        data.set(pe + 4, UInt16(bits == 64 ? 0x8664 : 0x14C))
        data.set(pe + 6, UInt16(1))
        data.set(pe + 20, UInt16(optSize))
        let opt = pe + 24
        data.set(opt, UInt16(bits == 64 ? 0x20B : 0x10B))
        let dirs = opt + (bits == 64 ? 108 : 92)
        data.set(dirs, UInt32(16))
        data.set(dirs + 4 + 8, sectionRVA)
        data.set(dirs + 4 + 12, UInt32(content.count))
        if dotNet { data.set(dirs + 4 + 14 * 8, sectionRVA) }
        let sh = opt + optSize
        for (i, byte) in ".rdata".utf8.enumerated() { data[sh + i] = byte }
        data.set(sh + 8, UInt32(content.count))
        data.set(sh + 12, sectionRVA)
        data.set(sh + 16, UInt32((content.count + 0x1FF) & ~0x1FF))
        data.set(sh + 20, UInt32(sectionOffset))
        data.append(content)
        return data
    }

    private static func le32(_ v: UInt32) -> Data {
        var d = Data(count: 4)
        d.set(0, v)
        return d
    }
}

extension Data {
    mutating func set(_ at: Int, _ v: UInt16) {
        self[at] = UInt8(v & 0xFF)
        self[at + 1] = UInt8(v >> 8)
    }
    mutating func set(_ at: Int, _ v: UInt32) {
        set(at, UInt16(truncatingIfNeeded: v))
        set(at + 2, UInt16(truncatingIfNeeded: v >> 16))
    }
}
