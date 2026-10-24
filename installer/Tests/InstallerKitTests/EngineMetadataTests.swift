import Foundation
import Testing
@testable import InstallerKit

@discardableResult
private func write(_ data: Data, _ path: String, in dir: URL) throws -> URL {
    let url = dir.appending(path: path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
    return url
}

private func le32(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24 & 0xFF)] }
private func le64(_ v: Int) -> [UInt8] { le32(v & 0xFFFF_FFFF) + le32(v >> 32) }

// GDPC v1: header, directory, contents. One file: res://project.godot.
private func pck(projectName: String) -> Data {
    var d = Data("GDPC".utf8) + Data(le32(1) + le32(4) + le32(2) + le32(0))
    d += Data(count: 64)
    d += Data(le32(1))
    let name = "res://project.godot".utf8
    d += Data(le32(name.count)) + Data(name)
    while d.count % 4 != 0 { d.append(0) }
    let fieldsAt = d.count
    d += Data(le64(0) + le64(0)) + Data(count: 16)
    let content = Data("[application]\nconfig/name=\"\(projectName)\"\n".utf8)
    d += content
    d.replaceSubrange(fieldsAt ..< fieldsAt + 8, with: le64(d.count - content.count))
    d.replaceSubrange(fieldsAt + 8 ..< fieldsAt + 16, with: le64(content.count))
    return d
}

// FORM with one GEN8 chunk; name at +40, display name at +96.
private func dataWin(name: String, displayName: String) -> Data {
    var gen8 = Data(count: 112)
    let nameAt = 16 + gen8.count, displayAt = nameAt + 4 + name.utf8.count + 1
    gen8.replaceSubrange(40 ..< 44, with: le32(nameAt))
    gen8.replaceSubrange(96 ..< 100, with: le32(displayAt))
    var strings = Data(le32(name.utf8.count)) + Data(name.utf8) + Data([0])
    strings += Data(le32(displayName.utf8.count)) + Data(displayName.utf8) + Data([0])
    var d = Data("FORM".utf8)
    d += Data(le32(8 + gen8.count + strings.count))
    d += Data("GEN8".utf8) + Data(le32(gen8.count)) + gen8 + strings
    return d
}

// [u32 length]["DefaultCompany"][pad][u32 length][product name]
private func globalGameManagers(productName: String) -> Data {
    var d = Data(le32(14)) + Data("DefaultCompany".utf8)
    while d.count % 4 != 0 { d.append(0) }
    d += Data(le32(productName.utf8.count)) + Data(productName.utf8)
    return d
}

// | u32 4 | u32 header payload | u32 json length | json + pad | files
private func asar(package: [String: String]) throws -> Data {
    let json = try JSONSerialization.data(withJSONObject: [
        "files": ["package.json": ["size": try JSONSerialization.data(withJSONObject: package).count, "offset": "0"]],
    ])
    var header = Data(le32(4)) + Data(le32(4 + json.count + (4 - json.count % 4) % 4))
    header += Data(le32(json.count)) + json
    while header.count % 4 != 0 { header.append(0) }
    return header + (try JSONSerialization.data(withJSONObject: package))
}

@Suite("Engine metadata")
struct EngineMetadataTests {

    @Test("The SteamRIP Silksong layout: app.info names it, the exe and its folder agree")
    func silksongLayout() throws {
        let dir = try tempFolder([
            "Hollow Knight Silksong/Hollow Knight Silksong.exe": "MZ",
            "Hollow Knight Silksong/UnityCrashHandler64.exe": "MZ",
            "Hollow Knight Silksong/Hollow Knight Silksong_Data/app.info": "Team Cherry\nHollow Knight Silksong\n",
            "_CommonRedist/dxwebsetup.exe": "MZ",
            "Read_Me_Instructions.txt": "x",
            "STEAMRIP » Free Pre-installed Steam Games.url": "x",
        ])
        let hints = EngineMetadata.hints(in: dir)
        #expect(hints.name == "Hollow Knight Silksong")
        #expect(hints.exeName == "Hollow Knight Silksong")
        #expect(hints.innerFolder == "Hollow Knight Silksong")
        let folderName = "Hollow-Knight-Silksong-SteamRIP.com"
        let id = GameIdentification.identify(
            steamAppID: hints.steamAppID, engineInfo: hints.name, productName: hints.productName,
            exeName: hints.exeName, innerFolder: hints.innerFolder,
            folderName: folderName, index: sampleIndex
        )
        #expect(id.match == nil)
        #expect(id.name == "Hollow Knight Silksong")
        let index = GameIndex([.init(appID: 9_999_999, name: "Hollow Knight: Silksong")])
        let hit = GameIdentification.identify(
            steamAppID: hints.steamAppID, engineInfo: hints.name, productName: hints.productName,
            exeName: hints.exeName, innerFolder: hints.innerFolder,
            folderName: folderName, index: index
        )
        #expect(hit.match?.appID == 9_999_999)
        #expect(hit.source == .engineInfo)
    }

    @Test("steam_appid.txt names the game by exact ID, in root or steam_settings")
    func steamAppIDFiles() throws {
        let plain = try tempFolder(["Game/Game.exe": "MZ", "Game/steam_appid.txt": "367520\n"])
        #expect(EngineMetadata.steamAppID(in: plain) == 367_520)
        let settings = try tempFolder(["Game/Game.exe": "MZ", "steam_settings/steam_appid.txt": "413150"])
        #expect(EngineMetadata.steamAppID(in: settings) == 413_150)
        let ini = try tempFolder(["Game/Game.exe": "MZ", "Game/steam_emu.ini": "[Settings]\nAppId=782330\n"])
        #expect(EngineMetadata.steamAppID(in: ini) == 782_330)
        let id = GameIdentification.identify(steamAppID: 367_520, folderName: "junk", index: sampleIndex)
        #expect(id.match?.appID == 367_520)
        #expect(id.source == .steamAppID)
    }

    @Test("An appID the index does not know still makes a match, for the cover")
    func unknownAppID() {
        let id = GameIdentification.identify(steamAppID: 8_888_888, exeName: "Frostpunk",
                                             folderName: "junk", index: sampleIndex)
        #expect(id.match == .init(appID: 8_888_888, name: "Frostpunk"))
        #expect(id.name == "Frostpunk")
    }

    @Test("Generic engine product names are ignored")
    func genericProductName() throws {
        let dir = try tempFolder([:])
        try write(samplePE(productName: "Unity Player", fileDescription: "Unity Player"), "game.exe", in: dir)
        #expect(PEVersion.gameName(of: dir.appending(path: "game.exe")) == nil)
        try write(samplePE(productName: "", fileDescription: "Hollow Knight"), "other.exe", in: dir)
        #expect(PEVersion.gameName(of: dir.appending(path: "other.exe")) == "Hollow Knight")
    }

    @Test("globalgamemanagers names the game when app.info is absent")
    func unityManagers() throws {
        let dir = try tempFolder([:])
        try write(globalGameManagers(productName: "Of Mice and Moggies"), "Game_Data/globalgamemanagers", in: dir)
        #expect(EngineMetadata.name(in: dir) == "Of Mice and Moggies")
    }

    @Test("Unreal: the shipping exe's product name, else the root launcher")
    func unreal() throws {
        let dir = try tempFolder(["Engine/Build.version": "{}"])
        try write(samplePE(productName: "Bright Hearts"), "BrightGame/Binaries/Win64/BrightGame-Win64-Shipping.exe", in: dir)
        #expect(EngineMetadata.name(in: dir) == "Bright Hearts")
        let plain = try tempFolder(["Engine/Build.version": "{}", "BrightGame.exe": "MZ"])
        try write(samplePE(productName: "UnrealEngine"), "BrightGame/Binaries/Win64/BrightGame-Win64-Shipping.exe", in: plain)
        #expect(EngineMetadata.name(in: plain) == "BrightGame")
    }

    @Test("Godot: project.godot inside a .pck gives the display name")
    func godot() throws {
        let dir = try tempFolder([:])
        try write(pck(projectName: "Road Trip"), "roadtrip.pck", in: dir)
        #expect(EngineMetadata.name(in: dir) == "Road Trip")
    }

    @Test("GameMaker: GEN8's display name wins over its name")
    func gameMaker() throws {
        let dir = try tempFolder([:])
        try write(dataWin(name: "gm_project", displayName: "Delicious Pixel Soup"), "data.win", in: dir)
        #expect(EngineMetadata.name(in: dir) == "Delicious Pixel Soup")
    }

    @Test("RPG Maker: Game.ini Title, then MV/MZ gameTitle")
    func rpgMaker() throws {
        let vx = try tempFolder(["Game.ini": "[Game]\nTitle=Alma Tactics\n"])
        #expect(EngineMetadata.name(in: vx) == "Alma Tactics")
        let mv = try tempFolder(["www/data/System.json": #"{"gameTitle":"Echoes of MV"}"#])
        #expect(EngineMetadata.name(in: mv) == "Echoes of MV")
    }

    @Test("Ren'Py: config.name in game/options.rpy")
    func renPy() throws {
        let dir = try tempFolder(["game/options.rpy": "define config.name = _(\"The Long Winter\")\n"])
        #expect(EngineMetadata.name(in: dir) == "The Long Winter")
    }

    @Test("Source: gameinfo.txt's game key")
    func source() throws {
        let dir = try tempFolder(["mod/gameinfo.txt": "\"GameInfo\"\n{\n\tgame\t\"Half-Life: Echoes\"\n}\n"])
        #expect(EngineMetadata.name(in: dir) == "Half-Life: Echoes")
    }

    @Test("Electron: package.json, then resources/app.asar's header")
    func electron() throws {
        let loose = try tempFolder(["package.json": #"{"name":"ldjam-entry","productName":"Jam Game"}"#])
        #expect(EngineMetadata.name(in: loose) == "Jam Game")
        let packed = try tempFolder([:])
        try write(asar(package: ["productName": "Packaged Electron Game"]), "resources/app.asar", in: packed)
        #expect(EngineMetadata.name(in: packed) == "Packaged Electron Game")
    }

    @Test("Epic: .egstore .item JSON, and the quoted string in a binary manifest")
    func epic() throws {
        let item = try tempFolder(["Ship.egstore/ship.item": #"{"DisplayName":"Star Ships","AppName":"Ship"}"#])
        #expect(EngineMetadata.name(in: item) == "Star Ships")
        let dir = try tempFolder([:])
        try write(Data(" binary DisplayName\":\"Dark Fleet\" more ".utf8), "Fleet.egstore/fleet.manifest", in: dir)
        #expect(EngineMetadata.name(in: dir) == "Dark Fleet")
    }

    @Test("Epic: the hidden .egstore folder is found at the root or one level down")
    func epicHidden() throws {
        let top = try tempFolder([".egstore/abc.item": #"{"DisplayName":"Hidden Store"}"#])
        #expect(EngineMetadata.name(in: top) == "Hidden Store")
        let nested = try tempFolder(["Game/.egstore/abc.item": #"{"DisplayName":"Nested Store"}"#])
        #expect(EngineMetadata.name(in: nested) == "Nested Store")
        // Other hidden trees stay out of the walk.
        let other = try tempFolder([".cache/Game.exe": "MZ"])
        #expect(EngineMetadata.mainExe(in: other) == nil)
    }
}
