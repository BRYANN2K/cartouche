// Reads Steam's appinfo.vdf cache and prints key=value metadata for one app on
// stdout. Usage: appinfo <appinfo.vdf> <appid>.
// With --platforms instead of an appid it prints mac= and windows= appid lists.
//
// common/icon is a 32x32 thumbnail. common/clienticon is the real multi-res
// icon, and the two hashes differ for most apps, so the icon cannot be
// inferred from the filesystem. Exits non-zero without printing on read
// failure.

import Foundation

let args = CommandLine.arguments
let platforms = args.count == 3 && args[2] == "--platforms"
guard args.count == 3, platforms || UInt32(args[2]) != nil else {
    fputs("usage: appinfo <appinfo.vdf> <appid>|--platforms\n", stderr)
    exit(2)
}

guard let file = FileManager.default.contents(atPath: args[1]) else {
    fputs("appinfo: cannot read \(args[1])\n", stderr)
    exit(1)
}
let bytes = [UInt8](file)

func findApp(_ b: [UInt8], _ appID: UInt32) throws -> [String: AppInfoVDF.Value]? {
    var found: [String: AppInfoVDF.Value]?
    _ = try AppInfoVDF.forEachApp(b) { id, keys in
        guard id == appID else { return true }
        found = try keys()
        return false
    }
    return found
}

// Steam treats an app without an oslist as Windows only.
// oslist can still say macos for a 32-bit build that no longer runs.
func printPlatforms(_ b: [UInt8]) throws {
    var mac: [UInt32] = []
    var windows: [UInt32] = []
    let complete = try AppInfoVDF.forEachApp(b) { id, keys in
        guard case .section(let common)? = try keys()["common"] else { return true }
        guard case .string(let oslist)? = common["oslist"] else {
            windows.append(id)
            return true
        }
        let systems = oslist.split(separator: ",")
        if systems.contains("macos") { mac.append(id) }
        if systems.contains("windows") { windows.append(id) }
        return true
    }
    guard complete else { throw AppInfoVDF.ParseError.truncated }
    print("mac=" + mac.map(String.init).joined(separator: ","))
    print("windows=" + windows.map(String.init).joined(separator: ","))
}

do {
    if platforms {
        try printPlatforms(bytes)
        exit(0)
    }
    let wantAppID = UInt32(args[2])!
    guard let app = try findApp(bytes, wantAppID) else {
        fputs("appinfo: no entry for appid \(wantAppID)\n", stderr)
        exit(1)
    }
    guard case .section(let common)? = app["common"] else {
        fputs("appinfo: appid \(wantAppID) has no common section\n", stderr)
        exit(1)
    }
    // A newline in a value would break the key=value framing the caller reads.
    for key in ["name", "icon", "clienticon", "logo"] {
        guard case .string(let v)? = common[key], !v.isEmpty else { continue }
        let flat = v.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        print("\(key)=\(flat)")
    }
} catch {
    fputs("appinfo: cannot parse \(args[1]): \(error)\n", stderr)
    exit(1)
}
