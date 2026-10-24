// Reads a disk image's .DS_Store back, independently of layout.swift, and
// prints each record. The background picture is printed as the path its alias
// and its bookmark resolve to, the way Finder resolves them.
//
//   swift dmg-check.swift <mounted volume>

import Foundation

// Reads the file back the way Finder does, independently of the writer above
func check(volume: URL) throws {
    let data = try Data(contentsOf: volume.appending(path: ".DS_Store"))
    func u32(_ at: Int) -> Int { Int(data[at..<at + 4].reduce(0) { $0 << 8 | UInt32($1) }) }
    guard u32(0) == 1, data[4..<8] == Data("Bud1".utf8) else { throw CocoaError(.fileReadCorruptFile) }
    let root = u32(8) + 4
    let count = u32(root)
    let offsets = (0..<count).map { u32(root + 8 + $0 * 4) }
    let tocStart = root + 8 + ((count + 255) / 256 * 256) * 4
    var at = tocStart + 4
    var toc: [String: Int] = [:]
    for _ in 0..<u32(tocStart) {
        let length = Int(data[at])
        toc[String(decoding: data[at + 1 ..< at + 1 + length], as: UTF8.self)] = u32(at + 1 + length)
        at += 1 + length + 4
    }
    func block(_ id: Int) -> Int { (offsets[id] & ~0x1F) + 4 }
    guard let dsdb = toc["DSDB"] else { throw CocoaError(.fileReadCorruptFile) }
    let node = block(u32(block(dsdb)))
    guard u32(node) == 0 else { throw CocoaError(.fileReadCorruptFile) }
    var p = node + 8
    for _ in 0..<u32(node + 4) {
        let length = u32(p)
        let name = String(decoding: stride(from: p + 4, to: p + 4 + length * 2, by: 2).map { UInt16(data[$0]) << 8 | UInt16(data[$0 + 1]) }, as: UTF16.self)
        p += 4 + length * 2
        let code = String(decoding: data[p..<p + 4], as: UTF8.self)
        let type = String(decoding: data[p + 4 ..< p + 8], as: UTF8.self)
        p += 8
        var value: Data
        switch type {
        case "blob": value = data[p + 4 ..< p + 4 + u32(p)]; p += 4 + u32(p)
        case "long", "shor", "type": value = data[p..<p + 4]; p += 4
        case "bool": value = data[p..<p + 1]; p += 1
        default: throw CocoaError(.fileReadCorruptFile)
        }
        var shown = value.map { String(format: "%02x", $0) }.joined()
        if type == "type" { shown = String(decoding: value, as: UTF8.self) }
        if type == "long" { shown = String(value.reduce(0) { $0 << 8 | Int($1) }) }
        if code == "Iloc" { shown = "\(u32(p - value.count)),\(u32(p - value.count + 4))" }
        if code == "pBBk" {
            var stale = false
            let url = try URL(resolvingBookmarkData: Data(value), bookmarkDataIsStale: &stale)
            shown = "bookmark -> \(url.path(percentEncoded: false))"
        }
        if code == "bwsp" || code == "icvp" {
            let dict = try PropertyListSerialization.propertyList(from: Data(value), format: nil) as? [String: Any] ?? [:]
            if let aliasData = dict["backgroundImageAlias"] as? Data,
               let bookmark = CFURLCreateBookmarkDataFromAliasRecord(nil, aliasData as CFData)?.takeRetainedValue() {
                var stale = false
                let url = try URL(resolvingBookmarkData: bookmark as Data, bookmarkDataIsStale: &stale)
                print("\(name) icvp.backgroundImageAlias -> \(url.path(percentEncoded: false))")
            }
            shown = dict.keys.sorted().map { key in
                key == "backgroundImageAlias" ? "\(key)=<alias>" : "\(key)=\(dict[key]!)"
            }.joined(separator: " ")
        }
        print("\(name) \(code) \(type) \(shown)")
    }
}

try check(volume: URL(filePath: CommandLine.arguments[1], directoryHint: .isDirectory))
