import Foundation

@testable import RetroArchKit

// Standalone emulator apps made in a scratch folder: an Info.plist as the real
// app carries it and a script for its executable. The script writes the
// arguments it got, one per line, then runs until the quit file appears or it
// gets SIGTERM. No real emulator is ever read, started or changed.
enum FakeEmulators {

    static let argsKey = "CARTOUCHE_FAKE_EMULATOR_ARGS"
    static let quitKey = "CARTOUCHE_FAKE_EMULATOR_QUIT"
    static let exitKey = "CARTOUCHE_FAKE_EMULATOR_EXIT"

    @discardableResult
    static func app(
        _ name: String, in folder: URL, bundleID: String, executable: String? = nil,
        version: String? = "1.0", build: String? = nil
    ) throws -> URL {
        let app = folder.appending(path: "\(name).app", directoryHint: .isDirectory)
        let macos = app.appending(path: "Contents/MacOS", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        let executable = executable ?? name
        var info: [String: Any] = [
            "CFBundleIdentifier": bundleID, "CFBundleExecutable": executable, "CFBundleName": name,
            "CFBundlePackageType": "APPL",
        ]
        if let version { info["CFBundleShortVersionString"] = version }
        if let build { info["CFBundleVersion"] = build }
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: app.appending(path: "Contents/Info.plist"))
        let script = macos.appending(path: executable)
        try """
        #!/bin/sh
        [ -n "$\(exitKey)" ] && exit "$\(exitKey)"
        : > "$\(argsKey)"
        for arg in "$@"; do printf '%s\\n' "$arg" >> "$\(argsKey)"; done
        trap 'exit 0' TERM
        while [ ! -e "$\(quitKey)" ]; do sleep 0.05; done
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return app
    }

    // Every emulator of the catalog, as its project ships it on macOS
    static func installAll(in folder: URL) throws {
        for emulator in EmulatorCatalog.all {
            try app(emulator.appNames[0], in: folder, bundleID: emulator.bundleIDs[0], executable: emulator.executableName)
        }
    }

    static func environment(args: URL, quit: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment[argsKey] = args.path(percentEncoded: false)
        environment[quitKey] = quit.path(percentEncoded: false)
        return environment
    }

    static func arguments(_ file: URL) -> [String] {
        ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    // A GameCube homebrew executable as Dolphin loads it: a DOL header with one
    // text section of a few PowerPC instructions (an endless loop). Written by
    // the test; no byte of any published game.
    static func homebrewDOL() -> Data {
        var dol = Data(count: 0x100)
        func put(_ value: UInt32, at offset: Int) {
            let bytes = withUnsafeBytes(of: value.bigEndian) { Data($0) }
            dol.replaceSubrange(offset..<(offset + 4), with: bytes)
        }
        let text: [UInt32] = [0x3860_0000, 0x4800_0000]  // li r3,0; b .
        put(0x100, at: 0x00)  // text section 0: file offset
        put(0x8000_3100, at: 0x48)  // its load address
        put(UInt32(text.count * 4), at: 0x90)  // its size
        put(0x8000_3100, at: 0xE0)  // entry point
        for word in text { dol.append(withUnsafeBytes(of: word.bigEndian) { Data($0) }) }
        return dol
    }
}
