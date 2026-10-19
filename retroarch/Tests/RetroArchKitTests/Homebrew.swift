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

    // 32 KiB with the title in the Game Boy header
    static func gb(_ title: String, fill: UInt8 = 0) -> Data {
        var rom = Data(repeating: fill, count: 32 * 1024)
        let name = Array(title.utf8.prefix(15))
        rom.replaceSubrange(0x134..<(0x134 + name.count), with: name)
        return rom
    }

    // The four Game Boy cartridges rows.json knows
    static let gameBoy: [(file: String, title: String, fill: UInt8)] = [
        ("quest.gb", "CARTOUCHE QUEST", 0), ("puzzle.gb", "CARTOUCHE PUZZL", 1),
        ("race.gb", "CARTOUCHE RACE", 2), ("maze.gb", "CARTOUCHE MAZE", 3),
    ]

    // A PlayStation data track whose system file boots the given serial
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

// The recorded rows as .rdb files, written as libretro-db writes them
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

    // Every recorded system written under the paths' database folder
    static func install(in paths: RetroArchPaths) throws {
        try FileManager.default.createDirectory(at: paths.database, withIntermediateDirectories: true)
        for (system, entries) in try rows() {
            try RDB.write(entries).write(to: paths.database.appending(path: "\(system).rdb"))
        }
    }

    // A database that never goes online: only what install() wrote
    static func offline(_ paths: RetroArchPaths) -> ContentDatabase {
        ContentDatabase(paths: paths, fetch: { _ in throw URLError(.notConnectedToInternet) })
    }
}
