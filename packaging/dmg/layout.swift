// Writes the .DS_Store that gives the disk image its window: size, background
// picture and icon positions. Finder is never asked to do it, so building the
// image needs no Automation permission and works the same in CI.
//
//   swift layout.swift <volume> <name>=<x>,<y>...
//
// packaging/tests/dmg-check.swift reads the result back.
//
// The format is Finder's buddy-allocated B-tree. Every record fits in one leaf
// node, which is all a disk image window needs.

import Foundation

let window = (width: 660, height: 400)
let iconSize = 112.0
let backgroundPath = ".background/background.tiff"
// Finder's bounds include the title bar
let titleBar = 28

struct Record {
    let name: String
    let code: String
    let type: String
    let payload: Data

    var bytes: Data {
        var out = Data()
        let utf16 = Array(name.utf16)
        out.append(be32(UInt32(utf16.count)))
        for unit in utf16 { out.append(be16(unit)) }
        out.append(Data(code.utf8))
        out.append(Data(type.utf8))
        if type == "blob" { out.append(be32(UInt32(payload.count))) }
        out.append(payload)
        return out
    }

    static func blob(_ name: String, _ code: String, _ data: Data) -> Record {
        Record(name: name, code: code, type: "blob", payload: data)
    }
}

func be16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.bigEndian) { Data($0) } }
func be32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.bigEndian) { Data($0) } }
func be64(_ v: UInt64) -> Data { withUnsafeBytes(of: v.bigEndian) { Data($0) } }

func plist(_ value: [String: Any]) throws -> Data {
    try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
}

func iconLocation(x: Int, y: Int) -> Data {
    be32(UInt32(x)) + be32(UInt32(y)) + be32(0xFFFF_FFFF) + be32(0xFFFF_0000)
}

// MARK: Alias record, version 2, as Finder's background picture reference

// Seconds between 1904-01-01, the HFS epoch, and 1970-01-01
let hfsEpochOffset = 2_082_844_800.0

func hfsDate(_ date: Date) -> UInt32 { UInt32(date.timeIntervalSince1970 + hfsEpochOffset) }
func hfsDateHighRes(_ date: Date) -> UInt64 { UInt64((date.timeIntervalSince1970 + hfsEpochOffset) * 65536) }

func pascal(_ text: String, size: Int) -> Data {
    var bytes = Array(text.replacingOccurrences(of: ":", with: "/").utf8.prefix(size - 1))
    bytes.insert(UInt8(bytes.count), at: 0)
    return Data(bytes + Array(repeating: 0, count: size - bytes.count))
}

func unicodeName(_ text: String) -> Data {
    let utf16 = Array(text.utf16)
    return utf16.reduce(be16(UInt16(utf16.count))) { $0 + be16($1) }
}

func alias(file: URL, volume: URL, volumeName: String) throws -> Data {
    let files = FileManager.default
    let fileAttributes = try files.attributesOfItem(atPath: file.path(percentEncoded: false))
    let folder = file.deletingLastPathComponent()
    let folderAttributes = try files.attributesOfItem(atPath: folder.path(percentEncoded: false))
    let created = fileAttributes[.creationDate] as? Date ?? Date()
    let volumeCreated = try volume.resourceValues(forKeys: [.volumeCreationDateKey]).volumeCreationDate ?? created
    // On HFS+, the inode number is the catalog node ID
    let cnid = UInt32((fileAttributes[.systemFileNumber] as? NSNumber)?.uint32Value ?? 0)
    let folderCNID = UInt32((folderAttributes[.systemFileNumber] as? NSNumber)?.uint32Value ?? 0)
    let relative = "/" + backgroundPath

    var body = Data()
    body.append(be16(0))                                  // kind: file
    body.append(pascal(volumeName, size: 28))
    body.append(be32(hfsDate(volumeCreated)))
    body.append(Data("H+".utf8))
    body.append(be16(5))                                  // ejectable disk
    body.append(be32(folderCNID))
    body.append(pascal(file.lastPathComponent, size: 64))
    body.append(be32(cnid))
    body.append(be32(hfsDate(created)))
    body.append(Data(count: 8))                           // creator and type codes
    body.append(be16(0xFFFF) + be16(0xFFFF))              // levels from and to: none
    body.append(be32(0))                                  // volume attributes
    body.append(be16(0))                                  // volume file system ID
    body.append(Data(count: 10))

    let tags: [(Int16, Data)] = [
        (0, Data(folder.lastPathComponent.utf8)),
        (1, be32(folderCNID)),
        (2, Data((volumeName + ":" + backgroundPath.replacingOccurrences(of: "/", with: ":")).utf8)),
        (14, unicodeName(file.lastPathComponent)),
        (15, unicodeName(volumeName)),
        (16, be64(hfsDateHighRes(volumeCreated))),
        (17, be64(hfsDateHighRes(created))),
        (18, Data(relative.utf8)),
        (19, Data("/Volumes/\(volumeName)".utf8)),
    ]
    for (tag, value) in tags {
        body.append(be16(UInt16(bitPattern: tag)) + be16(UInt16(value.count)) + value)
        if value.count % 2 == 1 { body.append(0) }
    }
    body.append(be16(0xFFFF) + be16(0))

    let size = 8 + body.count
    return Data(count: 4) + be16(UInt16(size)) + be16(2) + body
}

// MARK: The buddy-allocated file

// Blocks, as offsets from byte 4 of the file: the header, the DSDB record,
// the allocator's own block and the one leaf node
let headerBlock = (offset: 0, width: 5)
let dsdbBlock = (offset: 32, width: 5)
let rootBlock = (offset: 2048, width: 11)
let leafBlock = (offset: 4096, width: 12)

func address(_ block: (offset: Int, width: Int)) -> UInt32 { UInt32(block.offset | block.width) }

// Free blocks of each size around the used ones, as Finder's allocator expects
func freeLists(used: [(offset: Int, width: Int)]) -> [[Int]] {
    var lists = Array(repeating: [Int](), count: 32)
    func visit(_ offset: Int, _ width: Int) {
        let end = offset + (1 << width)
        let touching = used.filter { $0.offset < end && offset < $0.offset + (1 << $0.width) }
        if touching.isEmpty {
            lists[width].append(offset)
        } else if !(touching.count == 1 && touching[0].offset == offset && touching[0].width == width) {
            visit(offset, width - 1)
            visit(offset + (1 << (width - 1)), width - 1)
        }
    }
    visit(0, 31)
    return lists
}

func dsStore(_ records: [Record]) throws -> Data {
    let sorted = records.sorted {
        let a = $0.name.lowercased(), b = $1.name.lowercased()
        return a != b ? a < b : $0.code < $1.code
    }
    var leaf = be32(0) + be32(UInt32(sorted.count))
    for record in sorted { leaf.append(record.bytes) }
    guard leaf.count <= 1 << leafBlock.width else {
        throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "the records need more than one node"])
    }

    let dsdb = be32(2) + be32(0) + be32(UInt32(sorted.count)) + be32(1) + be32(0x1000)

    var root = be32(3) + be32(0)
    for block in [rootBlock, dsdbBlock, leafBlock] { root.append(be32(address(block))) }
    root.append(Data(count: (256 - 3) * 4))
    root.append(be32(1) + Data([4]) + Data("DSDB".utf8) + be32(1))
    for list in freeLists(used: [headerBlock, dsdbBlock, rootBlock, leafBlock]) {
        root.append(be32(UInt32(list.count)))
        for offset in list { root.append(be32(UInt32(offset))) }
    }

    var file = Data(count: 4 + leafBlock.offset + (1 << leafBlock.width))
    func put(_ data: Data, at offset: Int) {
        file.replaceSubrange(4 + offset ..< 4 + offset + data.count, with: data)
    }
    file.replaceSubrange(0..<4, with: be32(1))
    let rootSize = UInt32(1 << rootBlock.width)
    put(Data("Bud1".utf8) + be32(UInt32(rootBlock.offset)) + be32(rootSize) + be32(UInt32(rootBlock.offset))
        + Data([0x00, 0x00, 0x10, 0x0C, 0x00, 0x00, 0x00, 0x87, 0x00, 0x00, 0x20, 0x0B, 0x00, 0x00, 0x00, 0x00]), at: 0)
    put(dsdb, at: dsdbBlock.offset)
    put(root, at: rootBlock.offset)
    put(leaf, at: leafBlock.offset)
    return file
}

// MARK: Commands

func write(volume: URL, icons: [(String, Int, Int)]) throws {
    let name = try volume.resourceValues(forKeys: [.volumeNameKey]).volumeName ?? volume.lastPathComponent
    let picture = volume.appending(path: backgroundPath)
    let bounds = "{{200, 120}, {\(window.width), \(window.height + titleBar)}}"
    var records: [Record] = [
        .blob(".", "bwsp", try plist([
            "ContainerShowSidebar": false, "PreviewPaneVisibility": false, "ShowPathbar": false,
            "ShowSidebar": false, "ShowStatusBar": false, "ShowTabView": false, "ShowToolbar": false,
            "SidebarWidth": 0, "WindowBounds": bounds,
        ])),
        .blob(".", "icvp", try plist([
            "arrangeBy": "none", "backgroundType": 2,
            "backgroundColorRed": 0.96, "backgroundColorGreen": 0.96, "backgroundColorBlue": 0.97,
            "backgroundImageAlias": try alias(file: picture, volume: volume, volumeName: name),
            "gridOffsetX": 0.0, "gridOffsetY": 0.0, "gridSpacing": 100.0, "iconSize": iconSize,
            "labelOnBottom": true, "showIconPreview": true, "showItemInfo": false, "textSize": 13.0,
            "viewOptionsVersion": 1,
        ])),
        .blob(".", "pBBk", try picture.bookmarkData()),
        Record(name: ".", code: "vSrn", type: "long", payload: be32(1)),
        Record(name: ".", code: "vstl", type: "type", payload: Data("icnv".utf8)),
    ]
    for (file, x, y) in icons {
        records.append(.blob(file, "Iloc", iconLocation(x: x, y: y)))
    }
    try dsStore(records).write(to: volume.appending(path: ".DS_Store"))
}

let args = Array(CommandLine.arguments.dropFirst())
let icons = args.dropFirst().compactMap { item -> (String, Int, Int)? in
    let parts = item.split(separator: "=", maxSplits: 1)
    let xy = parts.last?.split(separator: ",").compactMap { Int($0) } ?? []
    guard parts.count == 2, xy.count == 2 else { return nil }
    return (String(parts[0]), xy[0], xy[1])
}
guard let volume = args.first, icons.count == args.count - 1 else {
    FileHandle.standardError.write(Data("usage: layout.swift <volume> <name>=<x>,<y>...\n".utf8))
    exit(2)
}
try write(volume: URL(filePath: volume, directoryHint: .isDirectory), icons: icons)
