import Foundation
import Testing
@testable import InstallerKit

let sampleIndex = GameIndex([
    .init(appID: 1_465_360, name: "CarX Street"),
    .init(appID: 292_030, name: "The Witcher 3: Wild Hunt"),
    .init(appID: 367_520, name: "Hollow Knight"),
    .init(appID: 632_470, name: "Disco Elysium - The Final Cut"),
    .init(appID: 782_330, name: "DOOM Eternal"),
    .init(appID: 1_086_940, name: "Baldur's Gate 3"),
    .init(appID: 1_091_500, name: "Cyberpunk 2077"),
    .init(appID: 413_150, name: "Stardew Valley"),
    .init(appID: 560_130, name: "Pillars of Eternity II: Deadfire"),
    .init(appID: 323_190, name: "Frostpunk"),
    .init(appID: 400, name: "Portal"),
    .init(appID: 1_207_658_924_000, name: "Unrelated Entry"),
])

@Suite("Game identification")
struct GameIndexTests {

    @Test("Ten installer folder names find their Steam App ID", arguments: [
        ("CarX Street [Offline Installer]", 1_465_360),
        ("The Witcher 3 Wild Hunt GOTY (Offline Installer) v4.04 + 2 DLCs", 292_030),
        ("Hollow_Knight_v1.5.78-GOG", 367_520),
        ("Disco Elysium - The Final Cut", 632_470),
        ("DOOM_Eternal", 782_330),
        ("Baldurs Gate 3 v4.1.1", 1_086_940),
        ("Cyberpunk 2077 [GOG] (Ultimate Edition)", 1_091_500),
        ("Stardew.Valley.1.6.8", 413_150),
        ("Pillars of Eternity II Deadfire", 560_130),
        ("Frostpunk GOTY Edition", 323_190),
    ])
    func foldersMatch(folder: String, appID: Int) {
        let id = GameIdentification.identify(folderName: folder, index: sampleIndex)
        #expect(id.match?.appID == appID)
        #expect(id.source == .folderName)
    }

    @Test("A sequel number is not noise, and an unknown game is not forced onto a known one")
    func noFalseMatch() {
        #expect(sampleIndex.match("Portal 2") == nil)
        #expect(sampleIndex.match("Portal Stories Mel") == nil)
        let id = GameIdentification.identify(folderName: "My Own Little Game v1.0", index: sampleIndex)
        #expect(id.match == nil)
        #expect(id.name == "My Own Little Game")
    }

    @Test("The installer title is matched before the folder name")
    func titleFirst() {
        let id = GameIdentification.identify(installerTitle: "CarX Street", folderName: "data-folder-01", index: sampleIndex)
        #expect(id.match?.appID == 1_465_360)
        #expect(id.source == .installerTitle)
    }

    @Test("A GOG info file is used first, and its name finds the Steam entry")
    func gogFirst() throws {
        let dir = try tempFolder(["game/goggame-1207658924.info": #"{"gameId":"1207658924","name":"The Witcher 3: Wild Hunt - Game of the Year Edition","playTasks":[{"isPrimary":true,"path":"bin\\x64\\witcher3.exe","type":"FileTask"}]}"#])
        let found = try #require(GOGInfo.find(in: dir))
        #expect(found.info.id == "1207658924")
        #expect(found.info.primaryExe == "bin/x64/witcher3.exe")
        let id = GameIdentification.identify(gog: found.info, installerTitle: "CarX Street", folderName: "x", index: sampleIndex)
        #expect(id.source == .gog)
        #expect(id.gogID == "1207658924")
        #expect(id.match?.appID == 292_030)
    }

    @Test("A GOG ID in the installer's file list is kept even without a match")
    func gogIDFromList() {
        #expect(GOGInfo.id(inFileList: ["app/goggame-1207658924.info", "app/game.exe"]) == "1207658924")
        let id = GameIdentification.identify(gogID: "1207658924", folderName: "Something New", index: sampleIndex)
        #expect(id.gogID == "1207658924")
        #expect(id.match == nil)
    }

    @Test("The exe's product name is the third source")
    func productName() throws {
        let exe = try tempFolder([:]).appending(path: "game.exe")
        try samplePE(productName: "Hollow Knight").write(to: exe)
        #expect(PEVersion.productName(of: exe) == "Hollow Knight")
        let id = GameIdentification.identify(productName: PEVersion.productName(of: exe), folderName: "HK", index: sampleIndex)
        #expect(id.source == .productName)
        #expect(id.match?.appID == 367_520)
    }

    @Test("A file that is not a PE has no product name")
    func notPE() throws {
        let exe = try tempFolder(["x.exe": "#!/bin/sh\n"]).appending(path: "x.exe")
        #expect(PEVersion.productName(of: exe) == nil)
    }

    @Test("The user's correction replaces the match")
    func correction() {
        let id = GameIdentification.identify(folderName: "Frostpunk", index: sampleIndex)
        let fixed = id.corrected(to: .init(appID: 782_330, name: "DOOM Eternal"))
        #expect(fixed.match?.appID == 782_330)
        #expect(fixed.source == .user)
    }

    @Test("Search finds games by word prefixes, exact name first")
    func search() {
        #expect(sampleIndex.search("witch").map(\.appID) == [292_030])
        #expect(sampleIndex.search("portal").first?.appID == 400)
        #expect(sampleIndex.search("").isEmpty)
    }
}

func samplePE(productName: String, fileDescription: String? = nil, companyName: String? = nil) -> Data {
    func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)] }
    func le32(_ v: Int) -> [UInt8] { le16(v & 0xFFFF) + le16(v >> 16 & 0xFFFF) }
    func utf16(_ s: String) -> [UInt8] { (s + "\0").utf16.flatMap { le16(Int($0)) } }
    func put(_ bytes: [UInt8], at offset: Int, in data: inout [UInt8]) {
        if data.count < offset + bytes.count { data += [UInt8](repeating: 0, count: offset + bytes.count - data.count) }
        data.replaceSubrange(offset..<offset + bytes.count, with: bytes)
    }

    var block = le16(0) + le16(0) + le16(1) + utf16("StringFileInfo")
    while block.count % 4 != 0 { block.append(0) }
    for (key, value) in [("ProductName", productName), ("FileDescription", fileDescription), ("CompanyName", companyName)] {
        guard let value else { continue }
        block += le16(0) + le16(0) + le16(1) + utf16(key)
        while block.count % 4 != 0 { block.append(0) }
        block += utf16(value)
        while block.count % 4 != 0 { block.append(0) }
    }

    var f = [UInt8](repeating: 0, count: 0x200)
    put([0x4D, 0x5A], at: 0, in: &f)
    put(le32(0x80), at: 0x3C, in: &f)
    put([0x50, 0x45, 0, 0] + le16(0x14C) + le16(1), at: 0x80, in: &f)
    put(le16(0xE0), at: 0x80 + 20, in: &f)
    let optional = 0x98
    put(le16(0x10B), at: optional, in: &f)
    put(le32(0x1000) + le32(0x1000), at: optional + 96 + 16, in: &f)
    let section = optional + 0xE0
    put(Array(".rsrc".utf8) + [0, 0, 0] + le32(0x1000) + le32(0x1000) + le32(0x1000) + le32(0x200), at: section, in: &f)
    let root = 0x200
    put(le16(0) + le16(1), at: root + 12, in: &f)
    put(le32(16) + le32(0x8000_0000 | 0x18), at: root + 16, in: &f)
    put(le16(0) + le16(1), at: root + 0x18 + 12, in: &f)
    put(le32(1) + le32(0x8000_0000 | 0x30), at: root + 0x28, in: &f)
    put(le16(0) + le16(1), at: root + 0x30 + 12, in: &f)
    put(le32(0x409) + le32(0x48), at: root + 0x40, in: &f)
    put(le32(0x1000 + 0x60) + le32(block.count), at: root + 0x48, in: &f)
    put(block, at: root + 0x60, in: &f)
    return Data(f)
}
