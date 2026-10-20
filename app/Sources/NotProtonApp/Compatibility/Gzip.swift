// Unpacks the gzip compat file. The Compression framework reads raw deflate only, so the gzip header and trailer are handled here.

import Compression
import Foundation
import zlib

enum Gzip {

    struct Damaged: Error, CustomStringConvertible {
        let description: String
    }

    static func decompress(_ data: Data, limit: Int = 256 * 1024 * 1024) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count >= 18, bytes[0] == 0x1f, bytes[1] == 0x8b, bytes[2] == 8 else {
            throw Damaged(description: "not a gzip file")
        }
        let flags = bytes[3]
        var offset = 10
        if flags & 0x04 != 0 {
            guard offset + 2 <= bytes.count else { throw Damaged(description: "truncated header") }
            offset += 2 + Int(bytes[offset]) + Int(bytes[offset + 1]) << 8
        }
        for flag: UInt8 in [0x08, 0x10] where flags & flag != 0 {
            while offset < bytes.count, bytes[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x02 != 0 { offset += 2 }
        guard offset < bytes.count - 8 else { throw Damaged(description: "truncated header") }

        var output = Data()
        let filter = try OutputFilter(.decompress, using: .zlib) { chunk in
            if let chunk {
                output.append(chunk)
                if output.count > limit { throw Damaged(description: "larger than \(limit) bytes") }
            }
        }
        do {
            try filter.write(Data(bytes[offset..<(bytes.count - 8)]))
            try filter.finalize()
        } catch let error as Damaged {
            throw error
        } catch {
            throw Damaged(description: "the compressed data is damaged")
        }

        let trailer = bytes.suffix(8).map(UInt32.init)
        let crc = trailer[0] | trailer[1] << 8 | trailer[2] << 16 | trailer[3] << 24
        let size = trailer[4] | trailer[5] << 8 | trailer[6] << 16 | trailer[7] << 24
        guard UInt32(truncatingIfNeeded: output.count) == size, crc32(output) == crc else {
            throw Damaged(description: "the checksum does not match")
        }
        return output
    }

    static func crc32(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { buffer in
            UInt32(zlib.crc32(0, buffer.baseAddress?.assumingMemoryBound(to: Bytef.self), uInt(buffer.count)))
        }
    }
}
