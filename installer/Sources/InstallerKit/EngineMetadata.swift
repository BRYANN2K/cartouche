// The name an installed game folder carries: store IDs, engine data files, the exe itself.
// Everything here is a small file read; nothing is ever run.

import Foundation

public enum EngineMetadata {

    // What the folder knows about the game, most trusted first.
    public struct Hints: Sendable, Equatable {
        public var steamAppID: Int?
        public var name: String?
        public var productName: String?
        public var exeName: String?
        public var innerFolder: String?
    }

    static let readCap = 8 << 20
    static let maxDepth = 4

    public static func hints(in root: URL, exe: URL? = nil) -> Hints {
        let main = exe ?? mainExe(in: root)
        var hints = Hints(steamAppID: steamAppID(in: root, exe: main), name: name(in: root, exe: main))
        if let main {
            hints.productName = PEVersion.gameName(of: main)
            let stem = main.deletingPathExtension().lastPathComponent
            if !isToolName(stem) { hints.exeName = stem }
            let inner = main.deletingLastPathComponent()
            if inner.standardizedFileURL != root.standardizedFileURL, !isGenericFolder(inner.lastPathComponent) {
                hints.innerFolder = inner.lastPathComponent
            }
        }
        return hints
    }

    // Store metadata and engine data, in the order of the formats that name the game for sure.
    public static func name(in root: URL, exe: URL? = nil) -> String? {
        epic(in: root) ?? unity(in: root, exe: exe) ?? unreal(in: root, exe: exe) ?? godot(in: root, exe: exe)
            ?? gameMaker(in: root) ?? rpgMaker(in: root) ?? renPy(in: root) ?? source(in: root) ?? electron(in: root)
    }

    // MARK: Steam app ID

    // steam_appid.txt within three levels (a steam_settings/ copy included), then AppId= in an ini
    // the game or its Steam client shim keeps next to the exe.
    public static func steamAppID(in root: URL, exe: URL? = nil) -> Int? {
        for url in entries(in: root, depth: 3) where url.lastPathComponent.lowercased() == "steam_appid.txt" {
            if let id = appIDFile(url) { return id }
        }
        var inis = entries(in: root, depth: 3).filter { url in
            ["steam_emu.ini", "steam_api.ini", "coldclientloader.ini"].contains(url.lastPathComponent.lowercased())
        }
        if let dir = exe?.deletingLastPathComponent() {
            inis += children(dir).filter { $0.pathExtension.lowercased() == "ini" }
        }
        for url in inis {
            if let text = smallText(url), let m = text.firstMatch(of: /(?im)^\s*AppId\s*=\s*([1-9]\d{1,9})/) {
                return Int(m.1)
            }
        }
        return nil
    }

    private static func appIDFile(_ url: URL) -> Int? {
        guard let text = smallText(url, cap: 64), let m = text.firstMatch(of: /([1-9]\d{1,9})/) else { return nil }
        return Int(m.1)
    }

    // MARK: Engines

    // Epic's .egstore: an .item is JSON, a .manifest/.mancpn is binary with the strings visible.
    // The folder is hidden, so it is looked up by name in the root and its subfolders rather than
    // by letting the whole walk into hidden trees.
    static func epic(in root: URL) -> String? {
        let parents = [root] + entries(in: root, depth: 1).filter(isDirectory)
        let stores = parents.flatMap { parent in
            ((try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
                .filter { $0.lastPathComponent.lowercased().hasSuffix(".egstore") && isDirectory($0) }
                .sorted { $0.path < $1.path }
        }
        for dir in stores {
            for file in children(dir) {
                switch file.pathExtension.lowercased() {
                case "item": if let name = jsonField("DisplayName", in: file) { return name }
                case "manifest", "mancpn": if let name = manifestField("DisplayName", in: file) { return name }
                default: break
                }
            }
        }
        return nil
    }

    // Unity: <Game>_Data/app.info is "company" then "product", one per line. When it is missing the
    // same pair sits in globalgamemanagers as consecutive length-prefixed strings.
    static func unity(in root: URL, exe: URL?) -> String? {
        let stem = exe?.deletingPathExtension().lastPathComponent.lowercased()
        let datas = entries(in: root, depth: 3)
            .filter { isDirectory($0) && $0.lastPathComponent.lowercased().hasSuffix("_data") }
            .sorted { a, b in
                let am = a.lastPathComponent.dropLast(5).lowercased() == stem
                let bm = b.lastPathComponent.dropLast(5).lowercased() == stem
                return am != bm ? am : a.path < b.path
            }
        for dir in datas {
            let info = dir.appending(path: "app.info")
            if let lines = smallText(info, cap: 64 << 10)?.split(whereSeparator: \.isNewline), lines.count > 1 {
                let name = lines[1].trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { return name }
            }
        }
        for dir in datas {
            if let data = bytes(dir.appending(path: "globalgamemanagers")),
               let name = unityPair(in: data, company: exe.flatMap(PEVersion.companyName)) { return name }
        }
        return nil
    }

    // The serialized PlayerSettings record: companyName then productName, each u32 length + UTF-8 + pad.
    static func unityPair(in data: Data, company: String?) -> String? {
        for anchor in [company, "DefaultCompany"].compactMap({ $0 }).map({ Data($0.utf8) }) where !anchor.isEmpty {
            var from = data.startIndex
            while let found = data[from...].firstRange(of: anchor) {
                defer { from = found.upperBound }
                let start = found.lowerBound - data.startIndex
                guard start >= 4, Int(data.u32(start - 4)) == anchor.count else { continue }
                var at = (found.upperBound - data.startIndex + 3) & ~3
                while at + 4 <= data.count {
                    let len = Int(data.u32(at))
                    guard len > 0, len < 300, at + 4 + len <= data.count,
                          let s = String(data: data[at + 4 ..< at + 4 + len], encoding: .utf8) else { break }
                    if printable(s) { return s }
                    at += 4 + ((len + 3) & ~3)
                }
            }
        }
        return nil
    }

    // Unreal: Engine/ plus <Project>/Binaries/Win64; the shipping exe's product name, else the root launcher.
    static func unreal(in root: URL, exe: URL?) -> String? {
        let all = entries(in: root, depth: maxDepth)
        guard all.contains(where: { isDirectory($0) && $0.lastPathComponent == "Engine" }) else { return nil }
        var project: String?
        for url in all where url.pathExtension.lowercased() == "exe"
            && url.path.lowercased().contains("/binaries/win") {
            if let name = PEVersion.gameName(of: url) { return name }
            if project == nil { project = url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().lastPathComponent }
        }
        for url in children(root) where url.pathExtension.lowercased() == "exe" && !isToolName(url.deletingPathExtension().lastPathComponent) {
            return url.deletingPathExtension().lastPathComponent
        }
        return project.flatMap { $0.isEmpty ? nil : $0 }
    }

    // Godot: project.godot inside a .pck next to the exe, or embedded at the exe's end.
    static func godot(in root: URL, exe: URL?) -> String? {
        for pck in entries(in: root, depth: 3) where pck.pathExtension.lowercased() == "pck" {
            if let name = godotPack(pck, base: 0) { return name }
        }
        guard let exe, let handle = try? FileHandle(forReadingFrom: exe) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > 12, (try? handle.seek(toOffset: size - 12)) != nil,
              let trailer = try? handle.read(upToCount: 12), trailer.u32(8) == 0x4350_4447 else { return nil }
        let base = UInt64(trailer.u32(0)) | UInt64(trailer.u32(4)) << 32
        return godotPack(exe, base: base)
    }

    // GDPC pack header, then its directory; each entry is name, offset, size, md5, flags (v2+).
    static func godotPack(_ url: URL, base: UInt64) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        func read(_ at: UInt64, _ n: Int) -> Data? {
            guard n > 0, (try? handle.seek(toOffset: at)) != nil,
                  let data = try? handle.read(upToCount: n), data.count == n else { return nil }
            return data
        }
        func u64(_ d: Data, _ i: Int) -> UInt64 { UInt64(d.u32(i)) | UInt64(d.u32(i + 4)) << 32 }
        guard let head = read(base, 104), head.u32(0) == 0x4350_4447 else { return nil }
        let version = head.u32(4)
        var directory = base + 84, fileBase = base
        switch version {
        case 0, 1: break
        case 2:
            fileBase = head.u32(20) & 2 != 0 ? base + u64(head, 24) : u64(head, 24)
            directory = base + 96
        case 3, 4:
            fileBase = base + u64(head, 24)
            directory = base + u64(head, 32)
        default: return nil
        }
        guard let countData = read(directory, 4) else { return nil }
        let count = Int(countData.u32(0))
        guard count > 0, count < 100_000 else { return nil }
        var at = directory + 4
        for _ in 0..<count {
            guard let lenData = read(at, 4) else { return nil }
            let nameLen = Int(lenData.u32(0))
            guard nameLen > 0, nameLen < 4096,
                  let nameData = read(at + 4, (nameLen + 3) & ~3) else { return nil }
            let path = String(decoding: nameData.prefix(nameLen), as: UTF8.self)
            at += 4 + UInt64((nameLen + 3) & ~3)
            guard let fields = read(at, version >= 2 ? 36 : 32) else { return nil }
            at += version >= 2 ? 36 : 32
            guard path == "res://project.godot" || path == "project.godot" else { continue }
            let offset = u64(fields, 0), size = Int(u64(fields, 8))
            guard size > 0, size < 1 << 20,
                  let content = read(version <= 1 ? offset : fileBase + offset, size),
                  let text = String(data: content, encoding: .utf8) else { return nil }
            if let m = text.firstMatch(of: /config\/name\s*=\s*"([^"\n]+)"/) { return String(m.1) }
            return nil
        }
        return nil
    }

    // GameMaker: FORM chunk list, GEN8's display name and name are offsets to u32-length strings.
    static func gameMaker(in root: URL) -> String? {
        for url in entries(in: root, depth: 3) where url.lastPathComponent.lowercased() == "data.win" {
            guard let data = bytes(url), data.count > 8, data.prefix(4).elementsEqual("FORM".utf8) else { continue }
            var at = 8
            while at + 8 <= data.count {
                let tag = String(decoding: data[at ..< at + 4], as: UTF8.self)
                let size = Int(data.u32(at + 4))
                if tag == "GEN8" {
                    for field in [104, 100, 96, 108] {
                        if let name = gen8String(data, at: at + 8 + field) { return name }
                    }
                    return gen8String(data, at: at + 8 + 40)
                }
                guard size > 0 else { break }
                at += 8 + size
            }
        }
        return nil
    }

    static func gen8String(_ data: Data, at field: Int) -> String? {
        guard field + 4 <= data.count else { return nil }
        let offset = Int(data.u32(field))
        guard offset > 0, offset + 4 <= data.count else { return nil }
        let len = Int(data.u32(offset))
        guard len > 0, len < 300, offset + 4 + len <= data.count,
              let s = String(data: data[offset + 4 ..< offset + 4 + len], encoding: .utf8),
              printable(s) else { return nil }
        return s
    }

    // RPG Maker: Game.ini's [Game] Title for XP/VX/VX Ace, System.json's gameTitle and package.json
    // for MV/MZ.
    static func rpgMaker(in root: URL) -> String? {
        for url in entries(in: root, depth: 2) where url.lastPathComponent.lowercased() == "game.ini" {
            guard let text = smallText(url) else { continue }
            var inGame = false
            for line in text.split(whereSeparator: \.isNewline) {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("[") { inGame = t.lowercased() == "[game]"; continue }
                if inGame, let eq = t.firstIndex(of: "="), t[..<eq].trimmingCharacters(in: .whitespaces).lowercased() == "title" {
                    let name = t[t.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty { return name }
                }
            }
        }
        for url in entries(in: root, depth: 4)
        where url.lastPathComponent.lowercased() == "system.json" && url.path.lowercased().contains("/data/") {
            if let name = jsonField("gameTitle", in: url) { return name }
        }
        return nil
    }

    // Ren'Py: config.name in the game/ scripts.
    static func renPy(in root: URL) -> String? {
        for game in entries(in: root, depth: 3)
        where isDirectory(game) && game.lastPathComponent.lowercased() == "game" {
            let files = children(game)
            guard files.contains(where: { $0.pathExtension.lowercased() == "rpyc" })
                || files.contains(where: { $0.pathExtension.lowercased() == "rpy" }) else { continue }
            let scripts = files.filter { $0.pathExtension.lowercased() == "rpy" }
                .sorted { a, b in
                    let am = a.lastPathComponent == "options.rpy", bm = b.lastPathComponent == "options.rpy"
                    return am != bm ? am : a.path < b.path
                }
            for file in scripts.prefix(8) {
                if let text = smallText(file, cap: 1 << 20),
                   let m = text.firstMatch(of: /config\.name\s*=\s*_\w*\s*\(\s*["']([^"'\n]+)["']|config\.name\s*=\s*["']([^"'\n]+)["']/) {
                    return String(m.1 ?? m.2 ?? "")
                }
            }
        }
        return nil
    }

    // Source mods: gameinfo.txt's "game" key.
    static func source(in root: URL) -> String? {
        for url in entries(in: root, depth: 3) where url.lastPathComponent.lowercased() == "gameinfo.txt" {
            guard let text = smallText(url, cap: 256 << 10) else { continue }
            if let m = text.firstMatch(of: /(?im)^[ \t]*"?game"?[ \t]+"([^"\n]+)"/)
                ?? text.firstMatch(of: /(?im)^[ \t]*"?title"?[ \t]+"([^"\n]+)"/) {
                return String(m.1)
            }
        }
        return nil
    }

    // Electron/NW.js: package.json on disk or inside resources/app.asar's JSON header tree.
    static func electron(in root: URL) -> String? {
        for url in [root.appending(path: "package.json"), root.appending(path: "app/package.json"),
                    root.appending(path: "resources/app/package.json")] {
            if let name = packageName(url) { return name }
        }
        for url in entries(in: root, depth: 3) where url.pathExtension.lowercased() == "asar" {
            if let name = asarPackageName(url) { return name }
        }
        return nil
    }

    static func packageName(_ url: URL) -> String? {
        jsonFields(in: url).flatMap { $0["productName"] ?? $0["product_name"] ?? $0["name"] ?? $0["title"] }
    }

    // | u32 4 | u32 header payload | u32 json size | json padded to 4 | data
    static func asarPackageName(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        func read(_ at: UInt64, _ n: Int) -> Data? {
            guard n > 0, (try? handle.seek(toOffset: at)) != nil,
                  let data = try? handle.read(upToCount: n), data.count == n else { return nil }
            return data
        }
        guard let head = read(0, 12), head.u32(0) == 4 else { return nil }
        let jsonLen = Int(head.u32(8))
        guard jsonLen > 0, jsonLen < 4 << 20, let jsonData = read(12, jsonLen),
              let tree = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else { return nil }
        func node(_ path: [String], in tree: [String: Any]) -> [String: Any]? {
            guard let key = path.first else { return tree }
            guard let next = (tree["files"] as? [String: Any])?[key] as? [String: Any] else { return nil }
            return node(Array(path.dropFirst()), in: next)
        }
        for path in [["package.json"], ["app", "package.json"], ["www", "package.json"], ["resources", "app", "package.json"]] {
            guard let file = node(path, in: tree), let size = (file["size"] as? Int) ?? (file["size"] as? String).flatMap(Int.init),
                  size > 0, size < 1 << 20 else { continue }
            let offset = (file["offset"] as? Int).map(UInt64.init) ?? (file["offset"] as? String).flatMap(UInt64.init) ?? 0
            let dataStart = 8 + UInt64(head.u32(4))
            guard let data = read(dataStart + offset, size), let name = packageName(data) else { continue }
            return name
        }
        return nil
    }

    // MARK: Exe choice

    // The biggest program that is not a tool: the exe the game most likely is.
    static func mainExe(in root: URL) -> URL? {
        let all = entries(in: root, depth: maxDepth).filter { $0.pathExtension.lowercased() == "exe" }
        let base = root.standardizedFileURL.path
        let named = all.filter { url in
            let relative = url.path.hasPrefix(base + "/") ? String(url.path.dropFirst(base.count + 1)) : url.lastPathComponent
            return !relative.lowercased().contains("redist/") && !isToolName(url.deletingPathExtension().lastPathComponent)
        }
        return (named.isEmpty ? all : named).max { size($0) < size($1) }
    }

    // MARK: Scanning helpers

    nonisolated(unsafe) private static let toolName =
        /(?i)(crash|report|launcher|setup|unins|redist|vcredist|vc_redist|dxweb|dxsetup|directx|dotnet|ue4prereq|easyanticheat|battleye|updat|patch|helper|handler|service|daemon|broker|installer|bootstrap|watchdog|quicksfv|sfx|extract|7z)/

    static func isToolName(_ stem: String) -> Bool {
        (try? toolName.firstMatch(in: stem)) != nil
    }

    // Wrapper folders that carry no name.
    private static let genericFolders: Set<String> = [
        "game", "app", "bin", "binaries", "win64", "win32", "x64", "x86", "x86_64", "data",
        "content", "files", "windows", "windowsnoeditor", "pc", "release", "shipping", "files",
    ]

    static func isGenericFolder(_ name: String) -> Bool {
        genericFolders.contains(name.lowercased()) || isToolName(name)
    }

    static func entries(in root: URL, depth: Int) -> [URL] {
        let fm = FileManager.default
        guard let walk = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                       options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        let base = root.standardizedFileURL.pathComponents.count
        var out: [URL] = []
        for case let url as URL in walk {
            if url.standardizedFileURL.pathComponents.count - base > depth { walk.skipDescendants(); continue }
            if out.count > 50_000 { break }
            out.append(url)
        }
        return out.sorted { $0.path < $1.path }
    }

    static func children(_ url: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? [])
            .sorted { $0.path < $1.path }
    }

    static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }

    static func size(_ url: URL) -> Int64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map(Int64.init) ?? 0
    }

    static func bytes(_ url: URL, cap: Int = readCap) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: cap)
    }

    static func smallText(_ url: URL, cap: Int = 1 << 20) -> String? {
        bytes(url, cap: cap).flatMap { String(data: $0, encoding: .utf8) }
    }

    static func printable(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return !t.isEmpty && t.allSatisfy { $0.isASCII && !$0.isNewline && ($0.isLetter || $0.isNumber || $0.isPunctuation || $0.isSymbol || $0 == " ") || !$0.isASCII && $0.isLetter }
    }

    // MARK: JSON and binary field reads

    static func jsonFields(in url: URL) -> [String: String]? {
        guard let data = bytes(url, cap: 4 << 20),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json.compactMapValues { $0 as? String }
    }

    static func jsonField(_ key: String, in url: URL) -> String? {
        jsonFields(in: url)?[key].flatMap { $0.isEmpty ? nil : $0 }
    }

    static func packageName(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return ["productName", "product_name", "name", "title"].lazy.compactMap { json[$0] as? String }.first
    }

    // Epic's binary manifests keep their fields readable: a needle, a colon, the value in quotes.
    static func manifestField(_ key: String, in url: URL) -> String? {
        guard let data = bytes(url, cap: 4 << 20) else { return nil }
        for needle in [key, key.lowercased(), "AppName"].map({ Data($0.utf8) }) {
            var from = data.startIndex
            while let found = data[from...].firstRange(of: needle) {
                defer { from = found.upperBound }
                let tail = data[found.upperBound...].prefix(256)
                guard let colon = tail.firstIndex(of: 0x3A),
                      let open = tail[colon...].firstIndex(of: 0x22),
                      let close = tail[tail.index(after: open)...].firstIndex(of: 0x22) else { continue }
                let s = String(decoding: tail[tail.index(after: open) ..< close], as: UTF8.self)
                if s.count < 200, s.contains(where: { $0.isLetter || $0.isNumber }), printable(s) { return s }
            }
        }
        return nil
    }
}
