import Foundation
import Testing
@testable import InstallerKit

// A .lnk as Wine's IShellLink::Save writes it: header, LinkInfo with the local
// path (ANSI, or Unicode with the larger LinkInfo header), then the working dir.
func shellLink(target: String, unicodeInfo: Bool = false) -> Data {
    func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)] }
    func le32(_ v: Int) -> [UInt8] { le16(v & 0xFFFF) + le16(v >> 16 & 0xFFFF) }
    var header = le32(0x4C) + [0x01, 0x14, 0x02, 0, 0, 0, 0, 0, 0xC0, 0, 0, 0, 0, 0, 0, 0x46]
    header += le32(0x2 | 0x10 | 0x80) + [UInt8](repeating: 0, count: 0x4C - 0x18)

    let volume = le32(0x11) + le32(3) + le32(0x1234) + le32(0x10) + [0]
    let headerSize = unicodeInfo ? 0x24 : 0x1C
    let ansi = Array(target.utf8) + [0], suffix: [UInt8] = [0]
    let wide = (target + "\0").utf16.flatMap { le16(Int($0)) }, wideSuffix = le16(0)
    let volumeAt = headerSize, baseAt = volumeAt + volume.count, suffixAt = baseAt + ansi.count
    let wideAt = suffixAt + suffix.count, wideSuffixAt = wideAt + wide.count
    var body = volume + ansi + suffix
    var info = le32(0) + le32(headerSize) + le32(1) + le32(volumeAt) + le32(baseAt) + le32(0) + le32(suffixAt)
    if unicodeInfo { info += le32(wideAt) + le32(wideSuffixAt); body += wide + wideSuffix }
    info += body
    info.replaceSubrange(0..<4, with: le32(info.count))

    let dir = target.split(separator: "\\").dropLast().joined(separator: "\\")
    let strings = le16(dir.utf16.count) + dir.utf16.flatMap { le16(Int($0)) }
    return Data(header + info + strings)
}

private func sized(_ url: URL, _ size: UInt64) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: url.path, contents: Data("MZ".utf8))
    let handle = try FileHandle(forWritingTo: url)
    try handle.truncate(atOffset: size)
    try handle.close()
}

private let uninstallReg = #"""
WINE REGISTRY Version 2
;; All keys relative to \\Machine

[Software\\Wow6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\Sample Game_is1] 1760900000
#time=1dc4100a3b2c4d0
"DisplayIcon"="C:\\Games\\Sample Game\\unins000.exe"
"DisplayName"="Sample Game"
"InstallLocation"="C:\\Games\\Sample Game\\"
"UninstallString"="\"C:\\Games\\Sample Game\\unins000.exe\""
"EstimatedSize"=dword:00a1b2c3

[Software\\Wine] 1760900000
"Version"="win10"
"""#

@Suite("Executable ranking")
struct ExeScanTests {

    private func tree() throws -> (prefix: URL, folder: URL) {
        let prefix = try tempFolder([:]).appending(path: "pfx")
        let folder = prefix.appending(path: "drive_c/Games/Sample Game")
        try sized(folder.appending(path: "game.exe"), 60_000_000)
        try sized(folder.appending(path: "SampleLauncher.exe"), 5_000_000)
        try sized(folder.appending(path: "unins000.exe"), 3_000_000)
        try sized(folder.appending(path: "_Redist/dxwebsetup.exe"), 300_000)
        try Data(uninstallReg.utf8).write(to: prefix.appending(path: "system.reg"))
        return (prefix, folder)
    }

    @Test("The Start Menu shortcut's target comes first, the launcher second, the uninstaller is not listed")
    func shortcutFirst() throws {
        let (prefix, folder) = try tree()
        let menu = prefix.appending(path: "drive_c/ProgramData/Microsoft/Windows/Start Menu/Programs/Sample Game")
        try FileManager.default.createDirectory(at: menu, withIntermediateDirectories: true)
        try shellLink(target: #"C:\Games\Sample Game\game.exe"#).write(to: menu.appending(path: "Sample Game.lnk"))
        try shellLink(target: #"C:\Games\Sample Game\unins000.exe"#).write(to: menu.appending(path: "Uninstall.lnk"))

        let scan = ExeDetector.scan(installFolder: folder, prefix: prefix)
        let names = scan.candidates.map { ($0.path as NSString).lastPathComponent }
        #expect(names == ["game.exe", "SampleLauncher.exe"])
        #expect(scan.candidates[0].reason == "From the Start Menu shortcut")
        #expect(scan.candidates[1].source == .launcher)
    }

    @Test("Without shortcuts, the exe the Uninstall key names is preferred")
    func registry() throws {
        let (prefix, folder) = try tree()
        let reg = uninstallReg.replacingOccurrences(of: #""DisplayIcon"="C:\\Games\\Sample Game\\unins000.exe""#,
                                                    with: #""DisplayIcon"="\"C:\\Games\\Sample Game\\SampleLauncher.exe\",0""#)
        try Data(reg.utf8).write(to: prefix.appending(path: "system.reg"))
        let scan = ExeDetector.scan(installFolder: folder, prefix: prefix)
        #expect(scan.candidates.first.map { ($0.path as NSString).lastPathComponent } == "SampleLauncher.exe")
        #expect(scan.candidates.first?.source == .registry)
    }

    @Test("Without shortcut or registry, the largest program wins")
    func largest() throws {
        let (prefix, folder) = try tree()
        try FileManager.default.removeItem(at: prefix.appending(path: "system.reg"))
        let scan = ExeDetector.scan(installFolder: folder, prefix: prefix)
        #expect(scan.candidates.map { ($0.path as NSString).lastPathComponent } == ["game.exe", "SampleLauncher.exe"])
        #expect(scan.candidates[0].source == .largest)
    }

    @Test("When the user picked another folder in the installer, the registered one is used")
    func movedFolder() throws {
        let (prefix, folder) = try tree()
        let scan = ExeDetector.scan(installFolder: prefix.appending(path: "drive_c/Games/Not There"), prefix: prefix)
        #expect(scan.installFolder.standardizedFileURL.path == folder.standardizedFileURL.path)
        #expect(scan.candidates.count == 2)
    }

    @Test("A GOG info file's play task is preferred over the size")
    func gogPrimary() throws {
        let (prefix, folder) = try tree()
        try FileManager.default.removeItem(at: prefix.appending(path: "system.reg"))
        let scan = ExeDetector.scan(installFolder: folder, prefix: prefix, primary: folder.appending(path: "SampleLauncher.exe"))
        #expect(scan.candidates.first?.source == .gogInfo)
    }

    @Test("Shell links with ANSI and Unicode local paths are read")
    func links() {
        #expect(ShellLink.parse(shellLink(target: #"C:\Games\X\x.exe"#))?.target == #"C:\Games\X\x.exe"#)
        #expect(ShellLink.parse(shellLink(target: #"C:\Jeux\Été\jeu.exe"#, unicodeInfo: true))?.target == #"C:\Jeux\Été\jeu.exe"#)
        #expect(ShellLink.parse(shellLink(target: #"C:\Games\X\x.exe"#))?.workingDirectory == #"C:\Games\X"#)
        #expect(ShellLink.parse(Data("not a link".utf8)) == nil)
    }

    @Test("Registry values are unescaped as Wine writes them")
    func registryParse() {
        let entries = WineRegistry.uninstallEntries(in: uninstallReg)
        #expect(entries.count == 1)
        #expect(entries[0].installLocation == #"C:\Games\Sample Game\"#)
        #expect(entries[0].displayName == "Sample Game")
        #expect(WineRegistry.unescape(#"Caf\x00e9"#) == "Café")
        #expect(WineRegistry.iconPath(#""C:\G\x.exe",0"#) == #"C:\G\x.exe"#)
    }
}
