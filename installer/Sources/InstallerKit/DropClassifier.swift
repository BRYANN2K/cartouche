// Works out what a drop on the app is: an installer, an already-installed game,
// ROMs, or an archive to unpack first. Pure and testable: the ArchiveEngine is
// injected, and every other input is a file on disk.
//
// The result model mirrors the app's DropResult in
// app/Sources/NotProtonApp/Library/Drop/DropResult.swift; the thin adapter that
// maps between them lives in
// app/Sources/NotProtonApp/Library/Drop/DropClassifierAdapter.swift.

import Foundation

public struct InstallerDrop: Sendable, Equatable {
    public var setup: URL
    public var name: String
    public var parts: Int
}

public struct GameDrop: Sendable, Equatable {
    public var folder: URL
    public var name: String
    public var steamAppID: Int?
    // Most likely first.
    public var executables: [URL]
    public var onExternalDrive: Bool
    public var bytes: Int64
}

public struct ConsoleGroup: Sendable, Equatable {
    public var console: String
    public var files: [URL]
}

public struct RomDrop: Sendable, Equatable {
    public var groups: [ConsoleGroup]
    public var unknown: [URL]
}

public enum DropFailureReason: Sendable, Equatable {
    case passwordProtected(URL)
    case unsupportedArchive(URL)
    case damagedArchive(URL)
    // A multi-volume archive with a gap in the numbering; the missing file's name.
    case missingVolume(URL, String)
    case insufficientSpace(URL, needed: Int64, available: Int64)
    case nothingRecognized([URL])
}

public indirect enum DropOutcome: Sendable, Equatable {
    case installer(InstallerDrop)
    case installedGame(GameDrop)
    case roms(RomDrop)
    case mixed([DropOutcome])
    case failed(DropFailureReason)
}

public struct DropClassifier: Sendable {

    public var extractor: ArchiveExtractor?
    // Where archives are unpacked for classification; the extracted folders
    // stay put so the app can import from them afterwards.
    public var workspace: URL

    public init(extractor: ArchiveExtractor? = nil, workspace: URL? = nil) {
        self.extractor = extractor
        self.workspace = workspace ?? FileManager.default.temporaryDirectory
            .appending(path: "cartouche-drops", directoryHint: .isDirectory)
    }

    // The extractor resolved from the bundled dylib; nil when it is absent.
    public static func live(workspace: URL? = nil) -> DropClassifier {
        DropClassifier(extractor: try? ArchiveExtractor.live(), workspace: workspace)
    }

    public func classify(
        _ urls: [URL],
        progress: @escaping @Sendable (ArchiveProgress) -> Void = { _ in }
    ) async throws -> DropOutcome {
        // A dropped .cue claims its data tracks anywhere in the drop, so the
        // cue/bin pair lands in one ps1 group even when dropped as loose files.
        let cueCovered = cueCoverage(urls)
        let dropped = Set(urls.map {
            $0.standardizedFileURL.path(percentEncoded: false).lowercased()
        })
        let units = group(urls)
        var outcomes: [DropOutcome] = []
        for unit in units {
            try Task.checkCancellation()
            outcomes.append(try await classifyUnit(unit, progress: progress,
                                                   cueCovered: cueCovered, dropped: dropped))
        }
        let flat = outcomes.flatMap { if case .mixed(let m) = $0 { return m }; return [$0] }
        // ROM files dropped together are one drop, not one group per file.
        var romGroups: [String: [URL]] = [:]
        var romUnknown: [URL] = []
        var rest: [DropOutcome] = []
        for outcome in flat {
            if case .roms(let r) = outcome {
                for g in r.groups { romGroups[g.console, default: []] += g.files }
                romUnknown += r.unknown
            } else {
                rest.append(outcome)
            }
        }
        if !romGroups.isEmpty || !romUnknown.isEmpty {
            rest.append(.roms(RomDrop(
                groups: romGroups.map { ConsoleGroup(console: $0.key, files: $0.value.sorted { $0.path < $1.path }) }
                    .sorted { $0.console < $1.console },
                unknown: romUnknown)))
        }
        return rest.count == 1 ? rest[0] : .mixed(rest)
    }

    // Data tracks named by every .cue in the drop: lowercase standardized path → URL.
    private func cueCoverage(_ urls: [URL]) -> [String: URL] {
        var covered: [String: URL] = [:]
        for url in urls where url.pathExtension.lowercased() == "cue" {
            for track in DiscTracks.cue(url) {
                covered[track.standardizedFileURL.path(percentEncoded: false).lowercased()] = track
            }
        }
        return covered
    }

    // Each classification unit is one thing the user dropped: a folder, a file,
    // or a whole multi-volume set whatever part was dropped. Files that are
    // installer parts fold into their setup's unit.
    func group(_ urls: [URL]) -> [[URL]] {
        var claimed = Set<String>()
        var volumes: [String: URL] = [:]
        var singles: [URL] = []

        for url in urls {
            if let set = ArchiveVolumes.set(for: url), let first = set.volumes.first {
                volumes[first.standardizedFileURL.path(percentEncoded: false)] = first
            } else {
                singles.append(url)
            }
        }
        for url in singles where url.pathExtension.lowercased() == "exe" && hasInstallerEvidence(url) {
            guard let scan = try? PartScanner.scan(url.deletingLastPathComponent()) else { continue }
            for part in scan.parts {
                claimed.insert(part.url.standardizedFileURL.path(percentEncoded: false))
            }
        }
        var units = volumes.values.sorted { $0.path < $1.path }.map { [$0] }
        units += singles.filter { !claimed.contains($0.standardizedFileURL.path(percentEncoded: false)) }.map { [$0] }
        return units
    }

    private func hasInstallerEvidence(_ exe: URL) -> Bool {
        DroppedFolder.hasInstallerSignature(exe)
            || (try? /(?i)^(setup|install)/.firstMatch(in: exe.lastPathComponent)) != nil
    }

    private func classifyUnit(_ unit: [URL], progress: @Sendable (ArchiveProgress) -> Void,
                              cueCovered: [String: URL], dropped: Set<String> = []) async throws -> DropOutcome {
        let url = unit[0]
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        if isDirectory { return classifyFolder(url, cueCovered: cueCovered, dropped: dropped) }
        if ArchiveVolumes.set(for: url) != nil || ArchiveDetector.isArchive(url) {
            return try await classifyArchive(url, progress: progress)
        }
        if url.pathExtension.lowercased() == "exe" { return classifyExecutable(url) }
        if let drop = roms([url], extraCovered: cueCovered, dropped: dropped) { return .roms(drop) }
        return .failed(.nothingRecognized([url]))
    }

    // MARK: folders

    private func classifyFolder(_ folder: URL, cueCovered: [String: URL] = [:],
                                dropped: Set<String> = []) -> DropOutcome {
        let classification = DroppedFolder.classify(folder)
        let root = classification.root
        if classification.kind == .installedGame { return installedGame(root) }
        if let drop = installer(root) { return .installer(drop) }
        if let roms = romFolder(folder, extraCovered: cueCovered, dropped: dropped) { return .roms(roms) }
        return .failed(.nothingRecognized([folder]))
    }

    private func installedGame(_ root: URL) -> DropOutcome {
        let gog = GOGInfo.find(in: root)?.info
        let steamID = (try? String(contentsOf: root.appending(path: "steam_appid.txt"), encoding: .utf8))
            .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let exes = ExeDetector.scan(gameFolder: root).candidates.map { URL(filePath: $0.path) }
        let removable = (try? root.resourceValues(forKeys: [.volumeIsRemovableKey]).volumeIsRemovable) ?? false
        return .installedGame(GameDrop(
            folder: root, name: gog?.name ?? GameName.clean(root.lastPathComponent), steamAppID: steamID,
            executables: exes, onExternalDrive: removable, bytes: DroppedFolder.size(of: root)))
    }

    // An installer needs evidence: an installer signature, numbered parts, or a setup-like name.
    private func installer(_ root: URL) -> InstallerDrop? {
        guard let scan = try? PartScanner.scan(root), let setup = scan.setup else { return nil }
        let signed = (try? FileManager.default.contentsOfDirectory(atPath: root.path(percentEncoded: false)))?
            .contains { $0.lowercased().hasSuffix(".exe") && DroppedFolder.hasInstallerSignature(root.appending(path: $0)) } ?? false
        let named = (try? /(?i)^(setup|install)/.firstMatch(in: setup.lastPathComponent)) != nil
        guard signed || named || !scan.parts.isEmpty else { return nil }
        return InstallerDrop(setup: setup,
                             name: Self.installerName(folder: root, setup: setup),
                             parts: max(1, scan.parts.count))
    }

    private func classifyExecutable(_ url: URL) -> DropOutcome {
        let folder = url.deletingLastPathComponent()
        let scan = (try? PartScanner.scan(folder)) ?? PartScan(folder: folder, setup: nil, parts: [], missing: [])
        guard hasInstallerEvidence(url) || !scan.parts.isEmpty else {
            // A game's own exe: the folder is what it installed to.
            return classifyFolder(folder)
        }
        let setup = scan.setup ?? url
        return .installer(InstallerDrop(setup: setup,
                                        name: Self.installerName(folder: folder, setup: setup),
                                        parts: max(1, scan.parts.count)))
    }

    static func installerName(folder: URL, setup: URL) -> String {
        if let title = try? InnoInspector.inspect(setup).title, !title.isEmpty { return title }
        // "setup_witcher3.exe" or the folder "The Witcher 3 [GOG]"
        let stem = setup.deletingPathExtension().lastPathComponent
        let cleaned = GameName.clean(stem.replacing(/(?i)^setup[_\- .]*/, with: ""))
        if cleaned.count > 2 { return cleaned }
        return GameName.clean(folder.lastPathComponent)
    }

    // MARK: archives

    private func classifyArchive(_ url: URL, progress: @Sendable (ArchiveProgress) -> Void) async throws -> DropOutcome {
        guard let extractor else { return .failed(.unsupportedArchive(url)) }
        do {
            let probe = try extractor.probe(url, isCancelled: { Task.isCancelled })
            if probe.hasEncryptedEntries { return .failed(.passwordProtected(url)) }
            if let roms = romArchive(probe, url: url) { return .roms(roms) }
            let result = try extractor.extract(url, to: workspace, progress: progress,
                                               isCancelled: { Task.isCancelled })
            return classifyExtracted(result, archive: url)
        } catch let error as ArchiveError {
            return .failed(Self.failure(error, url))
        } catch is CancellationError {
            // A cancel is not a damaged archive; the caller drops the result.
            throw CancellationError()
        } catch {
            return .failed(.damagedArchive(url))
        }
    }

    private func classifyExtracted(_ result: ExtractionResult, archive: URL) -> DropOutcome {
        let outcome = classifyFolder(result.root)
        if case .failed(.nothingRecognized) = outcome {
            return .failed(.nothingRecognized([archive]))
        }
        return outcome
    }

    static func failure(_ error: ArchiveError, _ url: URL) -> DropFailureReason {
        switch error {
        case .passwordProtected: return .passwordProtected(url)
        case .unsupportedFormat: return .unsupportedArchive(url)
        case .missingVolume(let name): return .missingVolume(url, name)
        case .insufficientSpace(let needed, let available):
            return .insufficientSpace(url, needed: needed, available: available)
        default: return .damagedArchive(url)
        }
    }

    // A zip whose members are all ROMs or harmless sidecars stays zipped: the
    // cores read .zip directly.
    private func romArchive(_ probe: ArchiveProbe, url: URL) -> RomDrop? {
        guard probe.format == .zip else { return nil }
        let hasCue = probe.entries.contains { $0.path.lowercased().hasSuffix(".cue") }
        var groups: [String: [URL]] = [:]
        var recognized = 0
        for entry in probe.entries where entry.kind == .file {
            let name = entry.path
            let ext = (name as NSString).pathExtension.lowercased()
            if ["bin", "img", "sub", "wav"].contains(ext), hasCue {
                // A .cue member's data track.
                recognized += 1
            } else if let console = ConsoleDetect.consoles(ext: ext).first {
                groups[console, default: []] = [url]
                recognized += 1
            } else if ConsoleDetect.sidecars.contains(ext) || name.hasSuffix("/") {
                continue
            } else {
                return nil
            }
        }
        guard recognized > 0 else { return nil }
        return RomDrop(groups: groups.map { ConsoleGroup(console: $0.key, files: $0.value) }
            .sorted { $0.console < $1.console }, unknown: [])
    }

    // MARK: ROMs

    // A folder's ROM files, or nil when nothing console-shaped is inside.
    private func romFolder(_ root: URL, extraCovered: [String: URL] = [:],
                           dropped: Set<String> = []) -> RomDrop? {
        var files: [URL] = []
        if let walk = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
            var seen = 0
            for case let url as URL in walk {
                if walk.level > 4 { walk.skipDescendants(); continue }
                seen += 1
                if seen > 20_000 { return nil }
                if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                    files.append(url)
                }
            }
        }
        return roms(files, extraCovered: extraCovered, dropped: dropped)
    }

    // Groups the URLs by console; nil when no ROM is found. Files that are
    // neither a ROM nor a sidecar land in `unknown`. `extraCovered` carries
    // tracks named by .cue files elsewhere in the same drop.
    private func roms(_ files: [URL], extraCovered: [String: URL] = [:],
                      dropped: Set<String> = []) -> RomDrop? {
        var groups: [String: [URL]] = [:]
        var unknown: [URL] = []
        var cues = extraCovered
        for url in files where url.pathExtension.lowercased() == "cue" {
            for track in DiscTracks.cue(url) {
                cues[track.standardizedFileURL.path(percentEncoded: false).lowercased()] = track
            }
        }
        var seen = Set<String>()
        for url in files {
            let path = url.standardizedFileURL.path(percentEncoded: false).lowercased()
            seen.insert(path)
            let ext = url.pathExtension.lowercased()
            if cues[path] != nil {
                groups["ps1", default: []].append(url)
            } else if ConsoleDetect.sidecars.contains(ext) {
                continue
            } else if let console = ConsoleDetect.console(for: url) {
                groups[console, default: []].append(url)
            } else {
                unknown.append(url)
            }
        }
        // A dropped .cue pulls in on-disk tracks that were not dropped elsewhere.
        for (lowered, track) in cues where !seen.contains(lowered) && !dropped.contains(lowered) {
            if FileManager.default.fileExists(atPath: track.path(percentEncoded: false)) {
                groups["ps1", default: []].append(track)
            }
        }
        let known = groups.values.reduce(0) { $0 + $1.count }
        guard known > 0 else { return nil }
        return RomDrop(groups: groups.map { ConsoleGroup(console: $0.key, files: $0.value.sorted { $0.path < $1.path }) }
            .sorted { $0.console < $1.console }, unknown: unknown)
    }
}

// MARK: - format sniffing

func head(_ url: URL, _ count: Int) -> Data? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    return try? handle.read(upToCount: count)
}

func head(_ url: URL, at offset: UInt64, _ count: Int) -> Data? {
    guard let handle = try? FileHandle(forReadingFrom: url),
          let _ = try? handle.seek(toOffset: offset)
    else { return nil }
    defer { try? handle.close() }
    return try? handle.read(upToCount: count)
}

enum ArchiveDetector {

    static let archiveExtensions: Set<String> = [
        "zip", "rar", "7z", "tar", "tgz", "tbz2", "txz", "tzst", "cab", "lzh", "lha",
        "tar.gz", "tar.xz", "tar.bz2", "tar.zst", "tar.lzma", "tar.lz",
    ]

    static func isArchive(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        if magic(url) != nil { return true }
        return archiveExtensions.contains { name.hasSuffix("." + $0) }
    }

    // Magic bytes say archive even when the extension lies.
    static func magic(_ url: URL) -> String? {
        guard let raw = head(url, 300) else { return nil }
        let b = [UInt8](raw)
        if b.count >= 4, b[0] == 0x50, b[1] == 0x4B, b[2] == b[3] - 1, [0x03, 0x05, 0x07].contains(b[2]) { return "zip" }
        if b.count >= 7, b.starts(with: [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07]) { return "rar" }
        if b.count >= 6, b.starts(with: [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]) { return "7z" }
        // ustar at offset 257
        if b.count >= 262, b[257] == 0x75, b[258] == 0x73, b[259] == 0x74, b[260] == 0x61, b[261] == 0x72 { return "tar" }
        // Compressed streams only count as archives when the name says tar.
        let name = url.lastPathComponent.lowercased()
        guard archiveExtensions.contains(where: { name.hasSuffix("." + $0) }) else { return nil }
        if b.starts(with: [0x1F, 0x8B]) { return "gzip" }
        if b.starts(with: [0x42, 0x5A, 0x68]) { return "bzip2" }
        if b.count >= 6, b.starts(with: [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]) { return "xz" }
        if b.starts(with: [0x28, 0xB5, 0x2F, 0xFD]) { return "zstd" }
        if b.count >= 6, b[0] == 0x5D, b[1] == 0x00 { return "lzma" }
        return "tar"
    }
}

// The FILE lines of a .cue, resolved next to it. Absolute paths and paths that leave the
// .cue's folder (through `..` or a symlink) are dropped.
enum DiscTracks {
    static func cue(_ url: URL) -> [URL] {
        guard let text = (try? String(contentsOf: url, encoding: .utf8))
            ?? (try? String(contentsOf: url, encoding: .isoLatin1)) else { return [] }
        let folder = url.deletingLastPathComponent().standardizedFileURL
        let root = resolved(folder)
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return text.split(whereSeparator: \.isNewline).compactMap { line -> URL? in
            let line = line.trimmingCharacters(in: .whitespaces)
            guard line.uppercased().hasPrefix("FILE ") else { return nil }
            var rest = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            let name: String
            if rest.hasPrefix("\""), let end = rest.dropFirst().firstIndex(of: "\"") {
                name = String(rest[rest.index(after: rest.startIndex)..<end])
            } else {
                if let space = rest.lastIndex(of: " ") { rest = String(rest[..<space]) }
                name = rest
            }
            guard !name.isEmpty, !name.hasPrefix("/") else { return nil }
            let track = folder.appending(path: name).standardizedFileURL
            guard resolved(track).hasPrefix(prefix) else { return nil }
            return track
        }
    }

    // resolvingSymlinksInPath only drops a leading /private for paths that exist, so a missing
    // track resolves through its nearest existing folder to stay comparable with the .cue's.
    private static func resolved(_ url: URL) -> String {
        let path = url.path(percentEncoded: false)
        if path == "/" || FileManager.default.fileExists(atPath: path) {
            return url.resolvingSymlinksInPath().path(percentEncoded: false)
        }
        let parent = resolved(url.deletingLastPathComponent())
        return (parent.hasSuffix("/") ? parent : parent + "/") + url.lastPathComponent
    }
}

// Extensions → console ids, mirroring RetroArchKit's ConsoleCatalog so results
// feed straight into it. Header checks disambiguate the shared ones.
enum ConsoleDetect {

    static let consolesByExtension: [String: [String]] = [
        "nes": ["nes"],
        "sfc": ["snes"], "smc": ["snes"],
        "gb": ["gb"], "gbc": ["gbc"], "gba": ["gba"], "nds": ["nds"],
        "n64": ["n64"], "z64": ["n64"], "v64": ["n64"],
        "md": ["genesis"], "gen": ["genesis"], "smd": ["genesis"], "bin": ["genesis", "atari2600"],
        "sms": ["mastersystem"], "gg": ["gamegear"], "pce": ["pce"],
        "a26": ["atari2600"],
        "cue": ["ps1"], "chd": ["ps1"], "m3u": ["ps1"],
        "iso": ["psp", "ps2", "gamecube", "wii", "xbox"],
        "cso": ["psp"], "pbp": ["psp"],
        "zso": ["ps2"], "mdf": ["ps2"],
        "gcm": ["gamecube"], "dol": ["gamecube"], "tgc": ["gamecube"],
        "rvz": ["gamecube", "wii"], "gcz": ["gamecube", "wii"], "ciso": ["gamecube", "wii"], "wia": ["gamecube", "wii"],
        "wbfs": ["wii"], "wad": ["wii"],
        "3ds": ["3ds"], "cci": ["3ds"], "cxi": ["3ds"], "3dsx": ["3ds"],
        "nsp": ["switch"], "xci": ["switch"], "nro": ["switch"],
        "xiso": ["xbox"],
    ]

    // Files that may ride along with a drop without making it unrecognizable.
    static let sidecars: Set<String> = [
        "txt", "nfo", "md", "rtf", "pdf", "jpg", "jpeg", "png", "gif", "bmp",
        "htm", "html", "xml", "json", "ds_store", "srm", "sav", "rtc", "state",
    ]

    static func consoles(ext: String) -> [String] { consolesByExtension[ext] ?? [] }

    static func console(for url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        let candidates = consoles(ext: ext)
        guard !candidates.isEmpty else { return nil }
        if let sniffed = sniff(url, ext: ext) { return sniffed }
        // A unique extension with no checkable magic: the extension decides.
        if candidates.count == 1, !requiresMagic(ext) { return candidates[0] }
        return nil
    }

    // Extensions whose magic is checked; a mismatch means "not this ROM".
    private static func requiresMagic(_ ext: String) -> Bool {
        ["nes", "gb", "gbc", "gba", "n64", "z64", "v64", "md", "gen", "smd", "bin",
         "cso", "pbp", "wbfs", "chd", "gcm", "iso", "sms", "gg"].contains(ext)
    }

    private static func sniff(_ url: URL, ext: String) -> String? {
        switch ext {
        case "nes":
            return head(url, 4) == Data("NES\u{1A}".utf8) ? "nes" : nil
        case "gb", "gbc":
            return gameboy(url)
        case "gba":
            return advanceLogo(url) ? "gba" : nil
        case "n64", "z64", "v64":
            guard let h = head(url, 4) else { return nil }
            return [Data([0x80, 0x37, 0x12, 0x40]), Data([0x37, 0x80, 0x40, 0x12]), Data([0x40, 0x12, 0x37, 0x80])]
                .contains(h) ? "n64" : nil
        case "md", "gen", "smd", "bin":
            return head(url, at: 0x100, 32)?.range(of: Data("SEGA".utf8)) != nil ? "genesis" : nil
        case "sms":
            return segaTicket(url) ? "mastersystem" : nil
        case "gg":
            return segaTicket(url) ? "gamegear" : nil
        case "cue":
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return text.uppercased().contains("FILE ") ? "ps1" : nil
        case "chd":
            return head(url, 8) == Data("MComprHD".utf8) ? "ps1" : nil
        case "pbp":
            return head(url, 4) == Data([0x00, 0x50, 0x42, 0x50]) ? "psp" : nil
        case "cso":
            return head(url, 4) == Data("CISO".utf8) ? "psp" : nil
        case "wbfs":
            return head(url, 4) == Data("WBFS".utf8) ? "wii" : nil
        case "gcm":
            return head(url, at: 0x1C, 4) == Data([0xC2, 0x33, 0x9F, 0x3D]) ? "gamecube" : nil
        case "iso", "rvz", "gcz", "ciso", "wia":
            return discImage(url)
        default:
            return nil
        }
    }

    // The 48-byte Nintendo logo shared by Game Boy and Game Boy Advance carts.
    private static func nintendoLogo(_ url: URL) -> Bool {
        let logo: [UInt8] = [
            0xCE, 0xED, 0x66, 0x66, 0xCC, 0x0D, 0x00, 0x0B, 0x03, 0x73, 0x00, 0x83,
            0x00, 0x0C, 0x00, 0x0D, 0x00, 0x08, 0x11, 0x1F, 0x88, 0x89, 0x00, 0x0E,
            0xDC, 0xCC, 0x6E, 0xE6, 0xDD, 0xDD, 0xD9, 0x99, 0xBB, 0xBB, 0x67, 0x63,
            0x6E, 0x0E, 0xEC, 0xCC, 0xDD, 0xDC, 0x99, 0x9F, 0xBB, 0xB9, 0x33, 0x3E,
        ]
        return head(url, at: 0x104, logo.count).map { [UInt8]($0) } == logo
    }

    // The 156-byte Nintendo logo every GBA cart carries at 0x04, as checked by
    // RetroArchKit's CartHeader.
    private static func advanceLogo(_ url: URL) -> Bool {
        let logo: [UInt8] = [
            0x24, 0xFF, 0xAE, 0x51, 0x69, 0x9A, 0xA2, 0x21, 0x3D, 0x84, 0x82, 0x0A,
            0x84, 0xE4, 0x09, 0xAD, 0x11, 0x24, 0x8B, 0x98, 0xC0, 0x81, 0x7F, 0x21,
            0xA3, 0x52, 0xBE, 0x19, 0x93, 0x09, 0xCE, 0x20, 0x10, 0x46, 0x4A, 0x4A,
            0xF8, 0x27, 0x31, 0xEC, 0x58, 0xC7, 0xE8, 0x33, 0x82, 0xE3, 0xCE, 0xBF,
            0x85, 0xF4, 0xDF, 0x94, 0xCE, 0x4B, 0x09, 0xC1, 0x94, 0x56, 0x8A, 0xC0,
            0x13, 0x72, 0xA7, 0xFC, 0x9F, 0x84, 0x4D, 0x73, 0xA3, 0xCA, 0x9A, 0x61,
            0x58, 0x97, 0xA3, 0x27, 0xFC, 0x03, 0x98, 0x76, 0x23, 0x1D, 0xC7, 0x61,
            0x03, 0x04, 0xAE, 0x56, 0xBF, 0x38, 0x84, 0x00, 0x40, 0xA7, 0x0E, 0xFD,
            0xFF, 0x52, 0xFE, 0x03, 0x6F, 0x95, 0x30, 0xF1, 0x97, 0xFB, 0xC0, 0x85,
            0x60, 0xD6, 0x80, 0x25, 0xA9, 0x63, 0xBE, 0x03, 0x01, 0x4E, 0x38, 0xE2,
            0xF9, 0xA2, 0x34, 0xFF, 0xBB, 0x3E, 0x03, 0x44, 0x78, 0x00, 0x90, 0xCB,
            0x88, 0x11, 0x3A, 0x94, 0x65, 0xC0, 0x7C, 0x63, 0x87, 0xF0, 0x3C, 0xAF,
            0xD6, 0x25, 0xE4, 0x8B, 0x38, 0x0A, 0xAC, 0x72, 0x21, 0xD4, 0xF8, 0x07,
        ]
        return head(url, at: 0x04, logo.count).map { [UInt8]($0) } == logo
    }

    private static func gameboy(_ url: URL) -> String? {
        guard nintendoLogo(url), let flag = head(url, at: 0x143, 1)?.first else { return nil }
        return flag == 0x80 || flag == 0xC0 ? "gbc" : "gb"
    }

    private static func segaTicket(_ url: URL) -> Bool {
        for offset: UInt64 in [0x7FF0, 0x3FF0, 0x1FF0] {
            if head(url, at: offset, 8) == Data("TMR SEGA".utf8) { return true }
        }
        return false
    }

    // Bounded scan of the disc image's early bytes for each system's tells.
    private static func discImage(_ url: URL) -> String? {
        if head(url, at: 0x1C, 4) == Data([0xC2, 0x33, 0x9F, 0x3D]) { return "gamecube" }
        if head(url, at: 0x18, 4) == Data([0x5D, 0x1C, 0x9E, 0xA3]) { return "wii" }
        guard let window = head(url, 8 << 20) else { return nil }
        if window.range(of: Data("PSP_GAME".utf8)) != nil { return "psp" }
        if window.range(of: Data("BOOT2".utf8)) != nil { return "ps2" }
        if window.range(of: Data("PLAYSTATION".utf8)) != nil
            || window.range(of: Data("BOOT = cdrom:\\".utf8)) != nil { return "ps1" }
        return nil
    }
}
