// Some Inno Setup installers do not unpack with Inno's own extractor: their script copies helper
// programs to the temp dir (ISDone.dll + unarc.dll / FreeArc, sometimes precomp, xtool, srep, 7z)
// and those do the decompression as separate processes. Detected before anything runs so the
// install can be given the environment these helpers need.

import Foundation

public struct ExternalUnpacker: Sendable, Equatable {
    // The helper module names found, sorted, e.g. ["isdone.dll", "unarc.dll"].
    public let helpers: [String]

    public init(helpers: [String]) {
        self.helpers = helpers
    }

    // Winetricks verbs applied to the fresh prefix before the installer runs: the Windows 10
    // version these installers expect, plus the Visual C++ runtimes the helpers link against.
    public var winetricksVerbs = ["win10", "vcrun2005", "vcrun2008", "vcrun2010"]

    // These setups draw their own interface; a silent switch only hides their questions and errors.
    public var showsOwnUI = true

    // Their temp dir and destination must stay short and ASCII or the helpers abort.
    public var shortPaths = true

    // The helpers size their decompression buffer as a percent of physical RAM, but they are
    // 32-bit processes that can address at most 4 GB. The common 75% of a 16 GB Mac asks for
    // 12 GB and fails on the spot (unarc "-11"/"-12"). Capping the share so it stays under
    // ~3 GB is what "enough virtual memory" means here; the wow64 prefix gives the rest.
    public static func memoryPercent(ramBytes: UInt64) -> Int {
        let ramMB = max(1, Int(ramBytes >> 20))
        return min(75, max(2, 3072 * 100 / ramMB))
    }

    // Module names the known unpackers ship. Substrings are compared on the file's base
    // name; exact names cover the short ones a substring would over-match.
    static let helperSubstrings = [
        "isdone", "unarc", "facompress", "cls-", "srep", "xtool", "precomp", "razor",
        "lolz", "mpz", "uharc", "unrar", "freearc", "oo2core", "liblz4", "pzlib",
    ]
    static let helperNames: Set<String> = [
        "arc.exe", "ua.exe", "7z.exe", "7za.exe", "7zr.exe", "7z.dll", "7zxa.dll", "msc.exe", "msc.dll",
    ]

    // The FreeArc signature ("ArC" + 0x01) opens every FreeArc archive.
    static let freeArcMagic: [UInt8] = [0x41, 0x72, 0x43, 0x01]

    public static func helperName(_ path: String) -> String? {
        let name = (path.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent.lowercased()
        // A helper is a module or program: the extension keeps names like "unarc-readme" or
        // a scratch folder containing "mpz" from counting.
        guard name.hasSuffix(".dll") || name.hasSuffix(".exe") || name.hasSuffix(".sys") else { return nil }
        guard helperNames.contains(name) || helperSubstrings.contains(where: { name.contains($0) }) else { return nil }
        return name
    }

    static func isFreeArc(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url),
              let bytes = try? handle.read(upToCount: freeArcMagic.count) else { return false }
        try? handle.close()
        return bytes.starts(with: freeArcMagic)
    }

    // Sources: the file list innoextract reads, and the setup's own folder. An "arc"/"bin"
    // part counts when it starts with the FreeArc signature.
    public static func detect(inno: InnoReport?, folder: URL) -> ExternalUnpacker? {
        var helpers = Set((inno?.files ?? []).compactMap(helperName))
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []
        for name in names {
            if let helper = helperName(name) { helpers.insert(helper) }
            let lower = name.lowercased()
            if lower.hasSuffix(".arc") || lower.hasSuffix(".bin"), isFreeArc(folder.appending(path: name)) {
                helpers.insert(name)
            }
        }
        guard !helpers.isEmpty else { return nil }
        return ExternalUnpacker(helpers: helpers.sorted())
    }
}
