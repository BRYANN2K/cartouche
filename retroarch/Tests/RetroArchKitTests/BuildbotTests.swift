import Foundation
import Testing

@testable import RetroArchKit

// A homebrew Super Nintendo cartridge written here: it turns the screen red
// and loops. 32 KiB LoROM with a valid header and checksum.
func testCartridgeSNES() -> Data {
    var rom = [UInt8](repeating: 0, count: 0x8000)
    let code: [UInt8] = [
        0x78,              // sei
        0x18, 0xFB,        // clc, xce: native mode
        0xA9, 0x8F, 0x8D, 0x00, 0x21,  // forced blank
        0x9C, 0x21, 0x21,  // colour 0
        0xA9, 0x1F, 0x8D, 0x22, 0x21,  // red, low byte
        0x9C, 0x22, 0x21,  // high byte
        0xA9, 0x0F, 0x8D, 0x00, 0x21,  // screen on, full brightness
        0x80, 0xFE,        // loop
    ]
    rom.replaceSubrange(0..<code.count, with: code)
    rom[0x20] = 0x40  // rti, for the interrupt vectors
    let title = Array("CARTOUCHE TEST CART  ".utf8)
    rom.replaceSubrange(0x7FC0..<0x7FC0 + 21, with: title)
    rom[0x7FD5] = 0x20  // LoROM
    rom[0x7FD7] = 0x05  // 32 KiB
    rom[0x7FD9] = 0x01
    for vector in stride(from: 0x7FE4, to: 0x8000, by: 2) {
        rom[vector] = 0x20
        rom[vector + 1] = 0x80
    }
    rom[0x7FFC] = 0x00  // reset
    rom[0x7FFD] = 0x80
    rom[0x7FDC] = 0xFF
    rom[0x7FDD] = 0xFF
    let sum = rom.reduce(0) { ($0 + Int($1)) & 0xFFFF }
    rom[0x7FDE] = UInt8(sum & 0xFF)
    rom[0x7FDF] = UInt8(sum >> 8)
    rom[0x7FDC] = UInt8(~sum & 0xFF)
    rom[0x7FDD] = UInt8((~sum >> 8) & 0xFF)
    return Data(rom)
}

// The real libretro buildbot, for the scenario that needs a real core: only
// with CARTOUCHE_NETWORK_TESTS=1 and a RetroArch build
@Suite(
    "Libretro buildbot", .serialized,
    .enabled(if: Rig.network && Rig.hasRetroArch, "set CARTOUCHE_NETWORK_TESTS=1 and CARTOUCHE_RETROARCH")
)
struct BuildbotTests {

    @Test func addingSuperNintendoGetsSnes9xThatLoadsInRetroArch() async throws {
        let work = try scratchFolder("buildbot")
        let paths = RetroArchPaths(root: work.appending(path: "cartouche"))
        let cores = CoreManager(paths: paths, session: URLSession(configuration: .ephemeral))
        let shelf = ConsoleShelf(paths: paths, cores: cores)

        try await shelf.add("snes")

        let folder = try FileManager.default.contentsOfDirectory(atPath: paths.cores.path)
        #expect(folder == ["snes9x_libretro.dylib"])
        let record = try #require(await cores.record("snes9x"))
        #expect(record.source.absoluteString
            == "https://buildbot.libretro.com/nightly/apple/osx/arm64/latest/snes9x_libretro.dylib.zip")

        let rom = work.appending(path: "Test Cart.sfc")
        try testCartridgeSNES().write(to: rom)
        let session = RetroArchSession(launch: Rig.launch(AppendConfig(paths: paths), in: work))
        try await session.start()
        try await session.load(core: try await cores.ready("snes9x"), content: rom)
        let status = try await session.status()
        #expect(status.state == .playing)
        #expect(status.system == "super_nes")
        try await Task.sleep(for: .milliseconds(500))
        if let folder = ProcessInfo.processInfo.environment["CARTOUCHE_EVIDENCE_DIR"] {
            try await session.screenshot().write(to: URL(fileURLWithPath: folder).appending(path: "p12-add-snes.png"))
        }
        #expect(await session.stop().way == .quit)
    }
}
