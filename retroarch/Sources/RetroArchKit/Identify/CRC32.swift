import Foundation

// The zlib CRC-32 the libretro database keys cartridges by. Slicing by 8, so a
// 4 MiB cartridge takes milliseconds.
public struct CRC32: Sendable {
    // Eight 256-entry tables, one after the other
    private static let table: [UInt32] = {
        var table = [UInt32](repeating: 0, count: 8 * 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 { c = c & 1 == 1 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
            table[i] = c
        }
        for t in 1..<8 {
            for i in 0..<256 {
                let previous = table[(t - 1) * 256 + i]
                table[t * 256 + i] = (previous >> 8) ^ table[Int(previous & 0xFF)]
            }
        }
        return table
    }()

    public private(set) var value: UInt32 = 0

    public init() {}

    public mutating func update(_ data: Data) {
        data.withUnsafeBytes { update($0) }
    }

    public mutating func update(_ bytes: UnsafeRawBufferPointer) {
        var c = ~value
        Self.table.withUnsafeBufferPointer { t in
            var i = 0
            let count = bytes.count
            while i + 8 <= count {
                let one = c ^ (UInt32(bytes[i]) | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2]) << 16 | UInt32(bytes[i + 3]) << 24)
                c = t[7 * 256 + Int(one & 0xFF)] ^ t[6 * 256 + Int((one >> 8) & 0xFF)]
                    ^ t[5 * 256 + Int((one >> 16) & 0xFF)] ^ t[4 * 256 + Int(one >> 24)]
                    ^ t[3 * 256 + Int(bytes[i + 4])] ^ t[2 * 256 + Int(bytes[i + 5])]
                    ^ t[256 + Int(bytes[i + 6])] ^ t[Int(bytes[i + 7])]
                i += 8
            }
            while i < count {
                c = t[Int((c ^ UInt32(bytes[i])) & 0xFF)] ^ (c >> 8)
                i += 1
            }
        }
        value = ~c
    }

    public static func checksum(_ data: Data) -> UInt32 {
        var crc = CRC32()
        crc.update(data)
        return crc.value
    }

    // Read in 1 MiB pieces, from an offset, so a copier header can be skipped
    public static func checksum(of url: URL, skipping offset: Int = 0) throws -> UInt32 {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        var crc = CRC32()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { crc.update(chunk) }
        return crc.value
    }
}
