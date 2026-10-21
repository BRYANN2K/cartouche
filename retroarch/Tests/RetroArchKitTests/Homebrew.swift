import Foundation

@testable import RetroArchKit

// Synthetic homebrew game files the tests write themselves. None holds a byte
// of any published game; their checksums are in Fixtures/database/rows.json.
enum Homebrew {

    // 32 KiB of LoROM with its header named
    static func snes(title: String = "CARTOUCHE HOMEBREW", fill: UInt8 = 0x42) -> Data {
        var rom = Data(repeating: fill, count: 32 * 1024)
        let name = Array(title.utf8.prefix(21)) + Array(repeating: UInt8(0x20), count: max(0, 21 - title.utf8.count))
        rom.replaceSubrange(0x7FC0..<0x7FD5, with: name)
        rom[0x7FD5] = 0x20
        return rom
    }

    // 32 KiB with the logo and title in the Game Boy header
    static func gb(_ title: String, fill: UInt8 = 0) -> Data {
        var rom = Data(repeating: fill, count: 32 * 1024)
        rom.replaceSubrange(0x104..<0x134, with: CartHeader.gameBoyLogo)
        let name = Array(title.utf8.prefix(15))
        rom.replaceSubrange(0x134..<(0x134 + name.count), with: name)
        return rom
    }

    // 32 KiB as make_world.py writes it: entry branch, the logo, title, game
    // code and maker, the fixed byte and a correct header checksum
    static func gba(_ title: String, code: String = "CT00", fill: UInt8 = 0x00) -> Data {
        var rom = Data(repeating: fill, count: 32 * 1024)
        rom.replaceSubrange(0x00..<0x04, with: [0x2E, 0x00, 0x00, 0xEA])
        rom.replaceSubrange(0x04..<0xA0, with: CartHeader.advanceLogo)
        var name = Array(title.utf8.prefix(12))
        while name.count < 12 { name.append(0) }
        rom.replaceSubrange(0xA0..<0xAC, with: name)
        var gameCode = Array(code.utf8.prefix(4))
        while gameCode.count < 4 { gameCode.append(0x20) }
        rom.replaceSubrange(0xAC..<0xB0, with: gameCode)
        rom[0xB0] = 0x34
        rom[0xB1] = 0x32
        rom[0xB2] = 0x96
        let sum = rom[0xA0..<0xBD].reduce(0) { $0 + Int($1) }
        rom[0xBD] = UInt8(truncatingIfNeeded: -(0x19 + sum))
        return rom
    }

    static let gameBoy: [(file: String, title: String, fill: UInt8)] = [
        ("quest.gb", "CARTOUCHE QUEST", 0), ("puzzle.gb", "CARTOUCHE PUZZL", 1),
        ("race.gb", "CARTOUCHE RACE", 2), ("maze.gb", "CARTOUCHE MAZE", 3),
    ]

    static func psTrack(serial: String) -> Data {
        var track = Data(repeating: 0, count: 2352 * 26)
        let boot = Data("BOOT = cdrom:\\\(serial);1\r\nTCB = 4\r\n".utf8)
        let at = 2352 * 24 + 24
        track.replaceSubrange(at..<(at + boot.count), with: boot)
        return track
    }

    // A disc as Redump lays it out: a .cue naming its one .bin
    @discardableResult
    static func disc(_ name: String, serial: String, in folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try psTrack(serial: serial).write(to: folder.appending(path: "\(name).bin"))
        let cue = folder.appending(path: "\(name).cue")
        try "FILE \"\(name).bin\" BINARY\n  TRACK 01 MODE2/2352\n    INDEX 01 00:00:00\n"
            .write(to: cue, atomically: true, encoding: .utf8)
        return cue
    }
}

enum FixtureDatabase {
    static func rows() throws -> [String: [DatabaseEntry]] {
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: Fixtures.url("database/rows.json"))) as? [String: Any] ?? [:]
        var out: [String: [DatabaseEntry]] = [:]
        for (system, value) in json where !system.hasPrefix("_") {
            out[system] = (value as? [[String: Any]] ?? []).map { row in
                DatabaseEntry(
                    name: row["name"] as? String ?? "", romName: row["rom_name"] as? String,
                    crc: (row["crc"] as? String).flatMap { UInt32($0, radix: 16) },
                    md5: row["md5"] as? String, sha1: row["sha1"] as? String, serial: row["serial"] as? String,
                    size: (row["size"] as? NSNumber)?.uint64Value)
            }
        }
        return out
    }

    static func install(in paths: RetroArchPaths) throws {
        try FileManager.default.createDirectory(at: paths.database, withIntermediateDirectories: true)
        for (system, entries) in try rows() {
            try RDB.write(entries).write(to: paths.database.appending(path: "\(system).rdb"))
        }
    }

    static func offline(_ paths: RetroArchPaths) -> ContentDatabase {
        ContentDatabase(paths: paths, fetch: { _ in throw URLError(.notConnectedToInternet) })
    }
}
