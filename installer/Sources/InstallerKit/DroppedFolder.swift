// Tells an installer from a game that is already installed. Reads names, sizes and the first bytes of programs; runs nothing.

import Foundation

public enum GameMarker: String, Sendable, Equatable, CaseIterable {
    case unity, unreal, steamAPI, packages, innoUninstaller, largeProgram

    // Only a finished install has these, so they outweigh a setup-like name.
    var isStrong: Bool { self == .unity || self == .unreal || self == .innoUninstaller }
}

public struct FolderClassification: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case installer, installedGame }

    public let kind: Kind
    // The dropped folder, or the single folder an archive wrapped it in.
    public let root: URL
    public let markers: [GameMarker]
}

public enum DroppedFolder {

    static let largeProgram: Int64 = 10 << 20
    static let signatureBytes = 4 << 20
    static let markerDepth = 4

    nonisolated(unsafe) private static let installerName = /(?i)^(setup|install).*\.exe$/
    nonisolated(unsafe) private static let uninstaller = /(?i)^unins\d{3}\.exe$/
    private static let packageExtensions: Set<String> = ["pak", "pck", "arc", "vpk"]
    private static let signatures: [Data] = ["Inno Setup", "JR.Inno.Setup", "Nullsoft.NSIS", "NullsoftInst", "InstallShield"]
        .flatMap { [Data($0.utf8), $0.data(using: .utf16LittleEndian)!] }

    public static func classify(_ folder: URL) -> FolderClassification {
        let root = unwrap(folder)
        let top = visible(root)
        let exes = top.filter { $0.pathExtension.lowercased() == "exe" && !isUninstaller($0.lastPathComponent) }
        let markers = self.markers(in: root)
        func result(_ kind: FolderClassification.Kind) -> FolderClassification {
            FolderClassification(kind: kind, root: root, markers: markers)
        }

        if exes.contains(where: hasInstallerSignature) { return result(.installer) }
        let named = exes.contains { (try? installerName.wholeMatch(in: $0.lastPathComponent)) != nil }
        let parts = !((try? PartScanner.scan(root).parts) ?? []).isEmpty
        if named || parts, !markers.contains(where: \.isStrong) { return result(.installer) }
        if !markers.isEmpty || hasProgram(root) { return result(.installedGame) }
        return result(.installer)
    }

    public static func isUninstaller(_ name: String) -> Bool {
        (try? uninstaller.wholeMatch(in: name)) != nil
    }

    // Inno Setup, NSIS and InstallShield leave their name in the loader's manifest or version resource.
    public static func hasInstallerSignature(_ exe: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: exe) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: signatureBytes), head.starts(with: [0x4D, 0x5A]) else { return false }
        return signatures.contains { head.range(of: $0) != nil }
    }

    // Descends at most two single-folder levels, as archives wrap a game or installer.
    public static func unwrap(_ folder: URL) -> URL {
        var root = folder
        for _ in 0..<2 {
            let items = visible(root)
            let dirs = items.filter(isDirectory)
            let loose = items.contains { ["exe", "bin"].contains($0.pathExtension.lowercased()) }
            guard !loose, dirs.count == 1 else { break }
            root = dirs[0]
        }
        return root
    }

    public static func markers(in root: URL) -> [GameMarker] {
        let fm = FileManager.default
        guard let walk = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                                       options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        let base = root.standardizedFileURL.pathComponents.count
        var found: Set<GameMarker> = []
        var exeStems: Set<String> = [], dataStems: Set<String> = []
        var engine = false, binaries = false
        var seen = 0
        for case let url as URL in walk {
            seen += 1
            if seen > 50_000 { break }
            let parts = url.standardizedFileURL.pathComponents.dropFirst(base).map { $0.lowercased() }
            if parts.count >= markerDepth { walk.skipDescendants() }
            let name = parts.last ?? ""
            let parent = parts.dropLast().joined(separator: "/")
            if isDirectory(url) {
                if parts == ["engine"] { engine = true }
                if parts.count == 3, parts[1] == "binaries", parts[2] == "win64" { binaries = true }
                if name.hasSuffix("_data") { dataStems.insert(parent + "/" + name.dropLast(5)) }
                continue
            }
            let ext = url.pathExtension.lowercased()
            if name == "steam_api.dll" || name == "steam_api64.dll" { found.insert(.steamAPI) }
            if packageExtensions.contains(ext) { found.insert(.packages) }
            guard ext == "exe" else { continue }
            if isUninstaller(name) { found.insert(.innoUninstaller); continue }
            exeStems.insert(parent + "/" + name.dropLast(4))
            if size(url) >= largeProgram { found.insert(.largeProgram) }
        }
        if !exeStems.isDisjoint(with: dataStems) { found.insert(.unity) }
        if engine && binaries { found.insert(.unreal) }
        return GameMarker.allCases.filter(found.contains)
    }

    // Every byte of the game, for the copy and its space check.
    public static func size(of root: URL) -> Int64 {
        guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walk { total += size(url) }
        return total
    }

    private static func hasProgram(_ root: URL) -> Bool {
        guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return false }
        for case let url as URL in walk {
            if walk.level > markerDepth { walk.skipDescendants(); continue }
            if url.pathExtension.lowercased() == "exe", !isUninstaller(url.lastPathComponent) { return true }
        }
        return false
    }

    private static func visible(_ folder: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? [])
            .filter { $0.lastPathComponent != "__MACOSX" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }

    private static func size(_ url: URL) -> Int64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map(Int64.init) ?? 0
    }
}
