// installer-inspect <folder> [--verify] [--json]
// Prints what the launcher would show before installing. Never runs the installer.

import Foundation
import InstallerKit

let args = CommandLine.arguments.dropFirst()
guard let path = args.first(where: { !$0.hasPrefix("--") }) else {
    print("usage: installer-inspect <folder> [--verify] [--json]")
    exit(2)
}
let folder = URL(filePath: (path as NSString).expandingTildeInPath, directoryHint: .isDirectory)
let gb = { (b: Int64) in String(format: "%.1f GB", Double(b) / 1_073_741_824) }

let scan = try PartScanner.scan(folder)
var report: [String: Any] = [
    "name": GameName.clean(folder.lastPathComponent),
    "setup": scan.setup?.lastPathComponent ?? NSNull(),
    "parts": scan.parts.map { ["file": $0.url.lastPathComponent, "size": $0.size] },
    "missing": scan.missing,
    "compressed": scan.totalSize,
]

var heavy = false
var language: String?
if let setup = scan.setup {
    do {
        let inno = try InnoInspector.inspect(setup)
        heavy = inno.heavyDecompression
        // /LANG takes the installer's own language id, which is "en" here, not "english".
        language = inno.languages.first { $0.hasPrefix("en") } ?? inno.languages.first
        report["inno"] = [
            "title": inno.title ?? "", "version": inno.version ?? "", "languages": inno.languages,
            "passworded": inno.passworded, "heavyDecompression": inno.heavyDecompression,
            "decompressors": inno.decompressors, "customInterface": inno.customInterface,
            "downloadsDuringInstall": inno.downloadsDuringInstall, "redistributables": inno.redistributables,
        ]
    } catch {
        report["inno"] = ["error": "\(error)"]
    }
}
let space = SpaceEstimate.from(compressed: scan.totalSize, heavy: heavy)
report["space"] = ["installed": space.installed, "temporary": space.temporary]
report["command"] = InnoCommand(installDir: #"C:\Games\\#(report["name"]!)"#, mode: .guided, language: language).arguments

if let manifest = Checksums.findManifest(in: folder), let parsed = try? Checksums.parse(manifest) {
    var m: [String: Any] = ["file": manifest.path(percentEncoded: false).replacingOccurrences(of: folder.path(percentEncoded: false), with: ""),
                            "entries": parsed.entries.count, "mentionsOptionalParts": parsed.mentionsOptionalParts]
    if args.contains("--verify") {
        let start = Date()
        let results = await Checksums.verify(parsed)
        m["results"] = Dictionary(uniqueKeysWithValues: results.map { ($0.key.lastPathComponent, "\($0.value)") })
        m["seconds"] = Int(Date().timeIntervalSince(start).rounded())
    }
    report["checksums"] = m
}

if args.contains("--json") {
    let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: data, as: UTF8.self))
} else {
    print("Game:        \(report["name"]!)")
    print("Installer:   \(scan.setup?.lastPathComponent ?? "not found")")
    print("Parts:       \(scan.parts.count), \(gb(scan.totalSize))\(scan.missing.isEmpty ? "" : ", missing: \(scan.missing.joined(separator: ", "))")")
    if let inno = report["inno"] as? [String: Any] {
        if let e = inno["error"] { print("Inno Setup:  \(e)") } else {
            print("Inno Setup:  \(inno["version"]!), languages \(inno["languages"]!), password \(inno["passworded"]!)")
            print("Unpacking:   \(heavy ? "heavy (" + (inno["decompressors"] as! [String]).joined(separator: ", ") + ")" : "standard")")
            print("Interface:   \((inno["customInterface"] as! Bool) ? "custom window" : "standard"), downloads during install: \(inno["downloadsDuringInstall"]!)")
            print("Redist:      \((inno["redistributables"] as! [String]).joined(separator: ", "))")
        }
    }
    print("Space:       \(gb(space.installed)) installed + \(gb(space.temporary)) temporary (estimate)")
    print("Command:     setup.exe \((report["command"] as! [String]).joined(separator: " "))")
    if let c = report["checksums"] as? [String: Any] {
        print("Checksums:   \(c["entries"]!) entries in \(c["file"]!)\((c["mentionsOptionalParts"] as! Bool) ? ", some parts may be optional" : "")")
        if let r = c["results"] { print("Verified:    \(r) in \(c["seconds"]!) s") }
    }
}
