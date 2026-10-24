import Darwin
import Foundation
import InstallerKit

struct SteamLibrary: Sendable, Hashable {
    let root: URL

    var volume: String?

    var steamapps: URL { root.appending(path: "steamapps") }
    var compatdata: URL { steamapps.appending(path: "compatdata") }

    var displayName: String {
        guard let volume else { return root.lastPathComponent }
        return volume
    }
}

enum PrefixArch: Sendable, Equatable {
    case arm64
    case x86_64
    case i386

    init?(machine: UInt16) {
        switch machine {
        case 0xaa64: self = .arm64
        case 0x8664: self = .x86_64
        case 0x014c: self = .i386
        default: return nil
        }
    }
}

struct WinePrefix: Sendable, Hashable, Identifiable {
    // Who made the prefix and runs the game in it.
    enum Source: Sendable, Hashable {
        case steam
        case installer
        case store(GameSource)

        var key: String {
            switch self {
            case .steam: "steam"
            case .installer: "installer"
            case .store(let store): store.id
            }
        }

        var label: String {
            switch self {
            case .steam: GameSource.steam.name
            case .installer: GameSource.installer.name
            case .store(let store): store.name
            }
        }
    }

    let appID: String
    let name: String?
    let library: SteamLibrary
    let lastUsed: Date?
    var source: Source = .steam
    // The game's own folder for a prefix Cartouche made: <folder>/pfx beside its record.
    var folder: URL? = nil
    // The Wine the game's record names, for prefixes outside Steam.
    var runner: String? = nil

    var root: URL { folder ?? library.compatdata.appending(path: appID) }
    var pfx: URL { root.appending(path: "pfx") }

    var id: String {
        guard let folder else { return "\(library.root.path(percentEncoded: false))#\(appID)" }
        return "\(source.key)#\(folder.path(percentEncoded: false))"
    }

    var title: String { name ?? String(localized: "App \(appID)") }

    // Rebuilding swaps in a Steam compatibility tool's DLLs: Steam's own prefixes only.
    var canRebuild: Bool { source == .steam }
    // An installer game's files live in its prefix (drive_c/Games), so only Uninstall removes it.
    // A store game's files sit beside it and Cartouche boots a new prefix on the next Play.
    var canDelete: Bool { source != .installer }
    // The Wine to open tools with: Steam's tool from the build record, an installer game's
    // own launcher. A store game's Wine comes from its setup, which only the library resolves.
    var canRunTools: Bool {
        if case .store = source { return false }
        return true
    }
}

struct PrefixUsage: Sendable {
    let bytes: Int64
    let profileFiles: Int
}

struct PrefixBackup: Sendable, Hashable, Identifiable {
    let prefix: WinePrefix
    let url: URL
    let taken: Date?
    let bytes: Int64

    var id: String { url.path(percentEncoded: false) }
    var title: String { prefix.title }
}

// What holds a busy prefix's session up. The menu labels a Quit with it, and a
// launcher kills the session only when nothing foreign keeps it alive.
enum SessionResident: Sendable, Equatable {
    // A leftover of the game itself: its exe or a process in its install folder.
    case game
    // A store client in the same prefix, named for the menu: "Steam", "GOG GALAXY"…
    case store(String)
    // Another tracked game or a program the user opened, like winecfg or Explorer.
    case program(String)
    // Busy for real, but the probe could not read or name what keeps the session.
    case unknown
}

// How busy a prefix's wineserver session is. Both kinds of busy refuse destructive
// work; sessionOnly alone is the leftover the menu offers to end.
enum PrefixUse: Sendable, Equatable {
    // No lock, no server, nothing on it.
    case free
    // A wineserver is up but only Wine's own helpers hold it: the game itself is gone.
    case sessionOnly
    // The launch lock, a live client process, or an answer the probe could not read.
    case running(SessionResident)

    // wineserver -k ends the session only when what holds it is known leftovers:
    // Wine's own services or the exited game's own processes. A store client,
    // another game or a program the user opened keeps its session.
    var leftoversOnly: Bool {
        switch self {
        case .sessionOnly, .running(.game): true
        case .free, .running: false
        }
    }
}

enum PrefixStore {

    static func libraries(vdf: URL = SupportPaths.Steam.libraryFoldersVDF) -> [SteamLibrary] {
        guard let text = try? String(contentsOf: vdf, encoding: .utf8) else {
            return [library(at: SupportPaths.Steam.userData)]
        }

        var roots: [URL] = []
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: "\"").map(String.init)
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            guard fields.count >= 2, fields[0] == "path" else { continue }
            roots.append(URL(filePath: fields[1]))
        }

        if roots.isEmpty { roots = [SupportPaths.Steam.userData] }

        var seen: Set<String> = []
        return roots.compactMap { root in
            guard seen.insert(root.path(percentEncoded: false)).inserted else { return nil }
            return library(at: root)
        }
    }

    static func library(at root: URL) -> SteamLibrary {
        SteamLibrary(root: root, volume: volumeName(of: root))
    }

    static func volumeName(of root: URL) -> String? {
        guard
            let values = try? root.resourceValues(forKeys: [.volumeNameKey, .volumeIsRootFileSystemKey]),
            values.volumeIsRootFileSystem != true,
            let name = values.volumeName
        else { return nil }
        return name
    }

    static func all(
        libraries: [SteamLibrary] = PrefixStore.libraries(),
        userdata: URL = SupportPaths.Steam.userData.appending(path: "userdata")
    ) -> [WinePrefix] {
        scan(libraries: libraries, userdata: userdata, live: true)
    }

    // Entries whose prefix was deleted but whose backups were kept
    static func backupOnly(
        libraries: [SteamLibrary] = PrefixStore.libraries(),
        userdata: URL = SupportPaths.Steam.userData.appending(path: "userdata")
    ) -> [WinePrefix] {
        scan(libraries: libraries, userdata: userdata, live: false)
    }

    // The prefixes Cartouche made itself: each installer or imported game's installs/<slug>/pfx
    // and each store game's <store>/<slug>-<id>/pfx, named from the game's own record.
    // With live false, the games whose prefix is gone but whose backups were kept.
    static func games(
        installs: URL = GameFolder.installs,
        previous: [URL] = GameFolder.previous(),
        stores: StoreFolders = StoreFolders(root: SupportPaths.support.appending(path: "stores", directoryHint: .isDirectory)),
        live: Bool = true
    ) -> [WinePrefix] {
        var found: [WinePrefix] = []
        let folders = GameFolder.roots(current: installs, previous: previous).flatMap {
            (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        }
        for root in folders {
            guard let record = InstalledGames.record(in: GameFolder(root: root)) else { continue }
            found.append(gamePrefix(appID: root.lastPathComponent, name: record.name, folder: root,
                                    source: .installer, runner: runnerLabel(record)))
        }
        for store in [GameSource.epic, .gog, .amazon] {
            for record in stores.loadRecords(store) {
                found.append(gamePrefix(appID: record.id, name: record.title, folder: record.folder,
                                        source: .store(store), runner: nil))
            }
        }
        return found.filter { prefix in
            guard isDirectory(prefix.pfx) == live else { return false }
            return live || !backups(of: prefix).isEmpty
        }
        .sorted { ($0.lastUsed ?? .distantPast, $0.appID) > ($1.lastUsed ?? .distantPast, $1.appID) }
    }

    private static func gamePrefix(
        appID: String, name: String, folder: URL, source: WinePrefix.Source, runner: String?
    ) -> WinePrefix {
        let pfx = folder.appending(path: "pfx")
        return WinePrefix(
            appID: appID, name: name, library: library(at: folder.deletingLastPathComponent()),
            lastUsed: (try? pfx.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
            source: source, folder: folder, runner: runner)
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    // "Cartouche Wine 26.3", as the runner list names it, from what the record kept of the runner.
    static func runnerLabel(_ record: InstalledGame) -> String {
        let name: String
        if record.runnerID.hasPrefix("wine-crossover-") {
            name = "Cartouche Wine"
        } else if let kind = record.wineRunnerKind.flatMap(Runner.Kind.init(rawValue:)) {
            name = kind.name
        } else {
            return record.runnerID
        }
        guard let version = record.wineVersion, !version.isEmpty else { return name }
        return "\(name) \(version)"
    }

    private static func scan(libraries: [SteamLibrary], userdata: URL, live: Bool) -> [WinePrefix] {
        var shortcuts: [String: String]?
        var found: [WinePrefix] = []
        for library in libraries {
            let entries = (try? FileManager.default.contentsOfDirectory(
                at: library.compatdata,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )) ?? []

            for entry in entries {
                let appID = entry.lastPathComponent
                let pfx = entry.appending(path: "pfx")
                var isDirectory: ObjCBool = false
                let hasPfx = FileManager.default.fileExists(atPath: pfx.path(percentEncoded: false), isDirectory: &isDirectory)
                    && isDirectory.boolValue
                guard hasPfx == live else { continue }
                if !live, backups(of: WinePrefix(appID: appID, name: nil, library: library, lastUsed: nil)).isEmpty { continue }

                var name = appName(appID: appID, in: library)
                if name == nil, let id = UInt32(appID), id & 0x8000_0000 != 0 {
                    if shortcuts == nil { shortcuts = shortcutNames(userdata: userdata) }
                    name = shortcuts?[appID]
                }

                found.append(
                    WinePrefix(
                        appID: appID,
                        name: name,
                        library: library,
                        lastUsed: (try? pfx.resourceValues(forKeys: [.contentModificationDateKey]))?
                            .contentModificationDate
                    )
                )
            }
        }

        return found.sorted {
            ($0.lastUsed ?? .distantPast, $0.appID) > ($1.lastUsed ?? .distantPast, $1.appID)
        }
    }

    static func appName(appID: String, in library: SteamLibrary) -> String? {
        manifestValue("name", appID: appID, in: library)
    }

    static func shortcutNames(userdata: URL) -> [String: String] {
        let accounts = (try? FileManager.default.contentsOfDirectory(
            at: userdata, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        var names: [String: String] = [:]
        for account in accounts.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let vdf = account.appending(path: "config/shortcuts.vdf")
            guard let data = try? Data(contentsOf: vdf) else { continue }
            names.merge(shortcutNames(vdf: data)) { first, _ in first }
        }
        return names
    }

    static func shortcutNames(vdf data: Data) -> [String: String] {
        let bytes = [UInt8](data)
        var names: [String: String] = [:]
        var offset = 0

        func cString() -> String? {
            guard let end = bytes[offset...].firstIndex(of: 0) else { return nil }
            defer { offset = end + 1 }
            return String(decoding: bytes[offset..<end], as: UTF8.self)
        }

        func skip(_ count: Int) -> Bool {
            guard bytes.count - offset >= count else { return false }
            offset += count
            return true
        }

        // Binary KeyValues: type byte, key, value; 0x08 closes a map.
        func map(depth: Int) -> Bool {
            guard depth < 16 else { return false }
            var appID: UInt32?
            var appName: String?
            while offset < bytes.count {
                let type = bytes[offset]
                offset += 1
                if type == 0x08 { break }
                guard let key = cString()?.lowercased() else { return false }
                switch type {
                case 0x00:
                    guard map(depth: depth + 1) else { return false }
                case 0x01:
                    guard let value = cString() else { return false }
                    if key == "appname" { appName = value }
                case 0x02:
                    guard bytes.count - offset >= 4 else { return false }
                    if key == "appid" {
                        appID = bytes[offset..<offset + 4].reversed().reduce(0) { $0 << 8 | UInt32($1) }
                    }
                    offset += 4
                case 0x03, 0x04, 0x06:
                    guard skip(4) else { return false }
                case 0x07, 0x0a:
                    guard skip(8) else { return false }
                default:
                    return false
                }
            }
            if let appID, let appName, !appName.isEmpty { names[String(appID)] = appName }
            return true
        }

        _ = map(depth: 0)
        return names
    }

    static func installDirectory(of prefix: WinePrefix) -> URL? {
        guard let folder = manifestValue("installdir", appID: prefix.appID, in: prefix.library)
        else { return nil }
        let url = prefix.library.steamapps.appending(path: "common").appending(path: folder)
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) ? url : nil
    }

    private static func manifestValue(_ key: String, appID: String, in library: SteamLibrary) -> String? {
        let manifest = library.steamapps.appending(path: "appmanifest_\(appID).acf")
        guard let text = try? String(contentsOf: manifest, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: "\"").map(String.init)
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            if fields.count >= 2, fields[0] == key { return fields[1] }
        }
        return nil
    }

    static let backupPrefix = "pfx.previous"

    static func backupClock() -> DateFormatter {
        let clock = DateFormatter()
        clock.locale = Locale(identifier: "en_US_POSIX")
        clock.dateFormat = "yyyyMMdd-HHmmss"
        return clock
    }

    static func backupDate(of backup: URL) -> Date? {
        let name = backup.lastPathComponent
        guard name.hasPrefix("\(backupPrefix)-") else { return nil }
        let stamp = name.dropFirst(backupPrefix.count + 1).prefix(15)
        return backupClock().date(from: String(stamp))
    }

    static func backupDetails(of prefix: WinePrefix) -> [PrefixBackup] {
        backups(of: prefix).map { url in
            PrefixBackup(
                prefix: prefix,
                url: url,
                taken: backupDate(of: url),
                bytes: directoryBytes(url)
            )
        }
    }

    static func backups(of prefix: WinePrefix) -> [URL] {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(
            at: prefix.root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return entries
            .filter { $0.lastPathComponent.hasPrefix(backupPrefix) }
            .filter { entry in
                var isDirectory: ObjCBool = false
                let found = fm.fileExists(
                    atPath: entry.path(percentEncoded: false), isDirectory: &isDirectory)
                return found && isDirectory.boolValue
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Keeps both the selected backup and the current prefix until promotion succeeds.
    @discardableResult
    static func restoreBackup(
        _ backup: PrefixBackup,
        serverRoot: URL = serverRoot,
        move: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }
    ) throws -> URL? {
        let prefix = backup.prefix
        let fm = FileManager.default
        let step = String(localized: "Restore prefix backup")
        func refuse(_ detail: String) -> StepFailure { StepFailure(step: step, detail: detail) }
        func ownedDirectory(_ url: URL) -> Bool {
            var info = stat()
            return lstat(url.path(percentEncoded: false), &info) == 0
                && info.st_mode & S_IFMT == S_IFDIR && info.st_uid == getuid()
        }
        let name = backup.url.lastPathComponent
        // A Steam entry sits in its library's compatdata under its numeric app ID; a game
        // Cartouche made has its own folder, named by the record that listed it.
        let placed: Bool
        if prefix.folder != nil {
            placed = prefix.source != .steam && !prefix.appID.isEmpty
        } else {
            placed = !prefix.appID.isEmpty && prefix.appID.allSatisfy({ $0.isASCII && $0.isNumber })
                && ownedDirectory(prefix.library.compatdata)
                && prefix.root.resolvingSymlinksInPath().path == prefix.library.root.resolvingSymlinksInPath()
                    .appending(path: "steamapps/compatdata").appending(path: prefix.appID).path
        }
        guard placed, ownedDirectory(prefix.root),
            backup.url.standardizedFileURL.deletingLastPathComponent().path == prefix.root.standardizedFileURL.path,
            name == backupPrefix || name.hasPrefix(backupPrefix + "-"),
            ownedDirectory(backup.url)
        else { throw refuse(String(localized: "The backup is not an owned prefix backup in this game's folder.")) }

        guard let claim = claim(prefix, root: serverRoot) else {
            throw refuse(String(localized: "\(prefix.title) is running. Quit the game first."))
        }
        defer { claim.release() }
        guard !serverIsBusy(backup.url, root: serverRoot, lsof: "/usr/sbin/lsof", drainTimeout: .seconds(2)) else {
            throw refuse(String(localized: "The backup is in use. Quit the game first."))
        }

        var info = stat()
        let exists = lstat(prefix.pfx.path(percentEncoded: false), &info) == 0
        guard !exists || ownedDirectory(prefix.pfx) else {
            throw refuse(String(localized: "The current prefix is not an owned directory."))
        }
        let record = prefix.root.appending(path: PrefixTools.buildRecordName)
        let hasRecord = lstat(record.path(percentEncoded: false), &info) == 0
        guard !hasRecord || (info.st_mode & S_IFMT == S_IFREG && info.st_uid == getuid()) else {
            throw refuse(String(localized: "The prefix build record is not an owned file."))
        }
        let token = UUID().uuidString
        let staging = prefix.root.appending(path: ".pfx.restore-\(token)")
        let savedRecord = prefix.root.appending(path: ".build.restore-\(token)")
        let parked = prefix.root.appending(path: "\(backupPrefix)-\(backupClock().string(from: .now))-\(token)")
        defer { try? fm.removeItem(at: staging) }
        try fm.copyItem(at: backup.url, to: staging)
        var parkedCurrent = false
        var parkedRecord = false
        do {
            if exists {
                try move(prefix.pfx, parked)
                parkedCurrent = true
            }
            if hasRecord {
                try move(record, savedRecord)
                parkedRecord = true
            }
            try move(staging, prefix.pfx)
        } catch {
            do {
                if parkedCurrent { try move(parked, prefix.pfx) }
                if parkedRecord { try move(savedRecord, record) }
            } catch {
                throw refuse(String(localized: "Restore could not roll back. Your original prefix is kept at \(parked.path(percentEncoded: false))."))
            }
            throw error
        }
        // A backup does not include the build record beside pfx. Let the restored
        // prefix's own timestamp identify its runner rather than keeping a stale record.
        if parkedRecord { try? fm.removeItem(at: savedRecord) }
        return exists ? parked : nil
    }

    static func usage(of prefix: WinePrefix) -> PrefixUsage {
        let bytes = directoryBytes(prefix.pfx)

        var files = 0
        let users = prefix.pfx.appending(path: "drive_c/users").path(percentEncoded: false)
        if let out = try? Shell.check("/usr/bin/find", [users, "-type", "f"]) {
            files = out.split(separator: "\n").filter { !$0.isEmpty }.count
        }

        return PrefixUsage(bytes: bytes, profileFiles: files)
    }

    enum SizeMetric {
        case privateSize, allocated
    }

    static func directoryBytes(_ url: URL, metric: SizeMetric = .privateSize) -> Int64 {
        struct FileID: Hashable {
            let device: dev_t
            let inode: ino_t
        }
        var seen: Set<FileID> = []
        var total: Int64 = 0
        var root = url.path(percentEncoded: false)
        while root.count > 1, root.hasSuffix("/") { root.removeLast() }
        var paths = [root]
        while let path = paths.popLast() {
            var info = stat()
            guard lstat(path, &info) == 0,
                seen.insert(FileID(device: info.st_dev, inode: info.st_ino)).inserted
            else { continue }
            total += metric == .allocated ? Int64(info.st_blocks) * 512 : privateBytes(path)
            guard info.st_mode & S_IFMT == S_IFDIR,
                let children = try? FileManager.default.contentsOfDirectory(atPath: path)
            else { continue }
            paths += children.map { path + "/" + $0 }
        }
        return total
    }

    // st_blocks * 512 is the fallback when ATTR_CMNEXT_PRIVATESIZE is unavailable.
    static func privateBytes(_ path: String) -> Int64 {
        var info = stat()
        guard lstat(path, &info) == 0 else { return 0 }
        let allocated = Int64(info.st_blocks) * 512

        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
        request.forkattr = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE)

        // getattrlist fills in a header, then the private size.
        var buffer = [UInt8](repeating: 0, count: 4 + MemoryLayout<attribute_set_t>.size + 8)
        let options = UInt32(FSOPT_NOFOLLOW) | UInt32(FSOPT_ATTR_CMN_EXTENDED)
        guard getattrlist(path, &request, &buffer, buffer.count, options) == 0 else { return allocated }

        return buffer.withUnsafeBytes { raw in
            let returned = raw.loadUnaligned(fromByteOffset: 4, as: attribute_set_t.self)
            guard returned.forkattr & attrgroup_t(ATTR_CMNEXT_PRIVATESIZE) != 0 else { return allocated }
            return raw.loadUnaligned(
                fromByteOffset: 4 + MemoryLayout<attribute_set_t>.size, as: Int64.self)
        }
    }

    static func arch(of prefix: WinePrefix) -> PrefixArch? {
        let dll = prefix.pfx.appending(path: "drive_c/windows/system32/ntdll.dll")
        guard let handle = try? FileHandle(forReadingFrom: dll) else { return nil }
        defer { try? handle.close() }

        guard let dos = try? handle.read(upToCount: 0x40), dos.count == 0x40 else { return nil }
        let lfanew = dos.withUnsafeBytes {
            UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 0x3c, as: UInt32.self))
        }
        do { try handle.seek(toOffset: UInt64(lfanew)) } catch { return nil }

        guard let head = try? handle.read(upToCount: 6), head.count == 6,
            Array(head.prefix(4)) == [0x50, 0x45, 0x00, 0x00]
        else { return nil }

        return PrefixArch(
            machine: head.withUnsafeBytes {
                UInt16(littleEndian: $0.loadUnaligned(fromByteOffset: 4, as: UInt16.self))
            }
        )
    }

    static var serverRoot: URL { URL(filePath: "/tmp/.wine-\(getuid())") }

    static func serverDirectory(of prefix: WinePrefix, root: URL = serverRoot) -> URL? {
        serverDirectory(forPfx: prefix.pfx, root: root)
    }

    static func serverDirectory(forPfx pfx: URL, root: URL = serverRoot) -> URL? {
        guard
            let attributes = try? FileManager.default.attributesOfItem(
                atPath: pfx.path(percentEncoded: false)
            ),
            let device = attributes[.systemNumber] as? Int,
            let inode = attributes[.systemFileNumber] as? Int
        else { return nil }

        return root.appending(
            path: "server-\(String(device, radix: 16))-\(String(inode, radix: 16))")
    }

    static func isInUse(
        _ prefix: WinePrefix, root: URL = serverRoot, lsof: String = "/usr/sbin/lsof",
        drainTimeout: DispatchTimeInterval = .seconds(2)
    ) -> Bool {
        isInUse(root: prefix.root, pfx: prefix.pfx, serverRoot: root, lsof: lsof, drainTimeout: drainTimeout)
    }

    // The same check for any folder/prefix pair, like an installer game's installs/<slug>.
    static func isInUse(
        root folder: URL, pfx: URL, serverRoot: URL = serverRoot, lsof: String = "/usr/sbin/lsof",
        drainTimeout: DispatchTimeInterval = .seconds(2)
    ) -> Bool {
        let lock = open(lockPath(in: folder), O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        if lock >= 0 {
            defer { FileLock.release(lock) }
            guard locked(lock) else { return true }
        } else if errno != ENOENT {
            return true
        }
        return serverIsBusy(pfx, root: serverRoot, lsof: lsof, drainTimeout: drainTimeout)
    }

    // The same probe with the busy kind told apart: free, or a live wineserver whose
    // remaining clients are only the session's own services — the game's window is
    // gone — or real work on the prefix. Both kinds of busy refuse destructive work;
    // only a session without a foreign client is safe to end with wineserver -k.
    static func use(
        root folder: URL, pfx: URL, serverRoot: URL = serverRoot, lsof: String = "/usr/sbin/lsof",
        drainTimeout: DispatchTimeInterval = .seconds(2),
        own: (name: String, root: URL)? = nil,
        siblings: [(name: String, root: URL)] = [],
        commOf: @Sendable (pid_t) -> String = { comm(of: $0) },
        infoOf: @Sendable (pid_t) -> GameProcesses.Info? = { GameProcesses.info(of: $0) },
        childrenOf: @Sendable (pid_t) -> [ProcessGroup.Entry] = {
            ProcessGroup(root: $0, prefix: nil).entries(environments: false)
        }
    ) -> PrefixUse {
        let lock = open(lockPath(in: folder), O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        if lock >= 0 {
            defer { FileLock.release(lock) }
            guard locked(lock) else { return .running(.game) }
        } else if errno != ENOENT {
            return .running(.unknown)
        }
        guard let dir = serverDirectory(forPfx: pfx, root: serverRoot),
              FileManager.default.fileExists(atPath: dir.path(percentEncoded: false))
        else { return .free }
        guard let result = try? Shell.run(
            lsof, ["-t", "+D", dir.path(percentEncoded: false)], drainTimeout: drainTimeout)
        else { return .running(.unknown) }
        let text = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.outputLost || !result.stderr.isEmpty { return .running(.unknown) }
        guard !text.isEmpty else { return .free }
        let pids = text.split(whereSeparator: \.isNewline)
            .compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
        // lsof answered but nothing parses to a pid: read that as busy, never as free.
        guard !pids.isEmpty else { return .running(.unknown) }

        var residents: [SessionResident] = []
        var servers: [pid_t] = []
        for pid in pids {
            let name = commOf(pid)
            if name.lowercased().hasPrefix("wineserver") {
                servers.append(pid)
            } else if !isSessionService(name, argv: infoOf(pid)?.arguments ?? []) {
                residents.append(resident(comm: name, info: infoOf(pid), own: own, siblings: siblings))
            }
        }
        // A client can hold the session while keeping no fd lsof can name in the
        // directory, so a services-only answer is not yet "game gone": wineserver
        // forks every Windows process it serves, and a live one shows under it.
        for pid in servers {
            for child in childrenOf(pid) where child.pid != pid
                    && !isSessionService(child.comm, argv: infoOf(child.pid)?.arguments ?? []) {
                residents.append(resident(comm: child.comm, info: infoOf(child.pid),
                                          own: own, siblings: siblings))
            }
        }
        // A named foreign client outranks an unreadable one, which outranks the
        // game's own leftovers: the label tells the truth and -k stays careful.
        if let named = residents.first(where: {
            if case .store = $0 { return true }
            if case .program = $0 { return true }
            return false
        }) { return .running(named) }
        if residents.contains(.unknown) { return .running(.unknown) }
        return residents.isEmpty ? .sessionOnly : .running(.game)
    }

    // The session's own services: they hold wineserver up but do no user work.
    // explorer counts only for its /desktop window — a user-opened Explorer, like
    // winecfg, is a real program the session serves, not a leftover.
    static let sessionServices: Set<String> = [
        "services.exe", "winedevice.exe", "plugplay.exe", "svchost.exe", "rpcss.exe",
        "tabtip.exe", "conhost.exe", "wineconsole.exe", "winedbg.exe", "wineboot.exe",
        "winemenubuilder", "winemenubuilder.exe",
    ]

    static func isSessionService(_ name: String, argv: [String]) -> Bool {
        let name = name.lowercased()
        if name.hasPrefix("wineserver") { return true }
        if name == "explorer.exe" {
            return argv.contains { $0.lowercased().hasPrefix("/desktop") }
        }
        return sessionServices.contains(name)
    }

    // A store client running in a game's own prefix keeps its real name in the menu.
    // The match tolerates pbi_comm cutting a long name at sixteen characters.
    static let storeClients: [(match: String, name: String)] = [
        ("steam", "Steam"),
        ("epicgameslauncher", "Epic Games Launcher"),
        ("epicwebhelper", "Epic Games Launcher"),
        ("galaxyclient", "GOG GALAXY"),
        ("galaxycommunication", "GOG GALAXY"),
        ("amazon games", "Amazon Games"),
    ]

    // A live, non-service client of the session: the game's own leftover under its
    // install folder, another tracked game under its own, a store client under its
    // real name, or a program the user opened, named by its exe.
    static func resident(
        comm: String, info: GameProcesses.Info?,
        own: (name: String, root: URL)?, siblings: [(name: String, root: URL)]
    ) -> SessionResident {
        if let own, let info, belongs(info, to: own.root) { return .game }
        if let info, let sibling = siblings.first(where: { belongs(info, to: $0.root) }) {
            return .program(sibling.name)
        }
        let name = programName(comm: comm, info: info)
        guard !name.isEmpty else { return .unknown }
        if let store = storeClients.first(where: {
            name.hasPrefix($0.match) || $0.match.hasPrefix(name)
        }) { return .store(store.name) }
        return .program(name.hasSuffix(".exe") ? String(name.dropLast(4)) : name)
    }

    // The client's exe name — pbi_comm first, then the exec path, then argv — split
    // on both separators since a Wine argv can be a Windows path.
    private static func programName(comm: String, info: GameProcesses.Info?) -> String {
        for base in [comm, info?.path ?? "", info?.arguments.first ?? ""] {
            if let last = base.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last {
                return String(last).lowercased()
            }
        }
        return ""
    }

    // A process belongs to an install folder when its exe or an argument lives in it.
    static func belongs(_ info: GameProcesses.Info, to root: URL) -> Bool {
        let folder = GameProcesses.folderPrefix(root)
        return info.path.hasPrefix(folder) || info.arguments.contains { $0.hasPrefix(folder) }
    }

    // The process's command name — "services.exe", the game's own exe name — as pbi_comm sees it.
    static func comm(of pid: pid_t) -> String {
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0
        else { return "" }
        return withUnsafeBytes(of: info.pbi_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    // A launch takes this lock while it sets the prefix up. Holding it stops a launch from starting partway through a rebuild/delete.
    static func claim(
        _ prefix: WinePrefix, root: URL = serverRoot, lsof: String = "/usr/sbin/lsof",
        drainTimeout: DispatchTimeInterval = .seconds(2)
    ) -> PrefixClaim? {
        let lock = open(lockPath(of: prefix), O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else {
            guard errno == ENOENT,
                !serverIsBusy(prefix.pfx, root: root, lsof: lsof, drainTimeout: drainTimeout)
            else { return nil }
            return PrefixClaim(fd: -1)
        }
        guard locked(lock), !serverIsBusy(prefix.pfx, root: root, lsof: lsof, drainTimeout: drainTimeout)
        else {
            FileLock.release(lock)
            return nil
        }
        return PrefixClaim(fd: lock)
    }

    private static func lockPath(of prefix: WinePrefix) -> String {
        lockPath(in: prefix.root)
    }

    private static func lockPath(in folder: URL) -> String {
        folder.appending(path: ".cartouche-prefix.lock").path(percentEncoded: false)
    }

    private static func locked(_ fd: Int32) -> Bool {
        var info = stat()
        return fstat(fd, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
            && flock(fd, LOCK_EX | LOCK_NB) == 0
    }

    private static func serverIsBusy(
        _ pfx: URL, root: URL, lsof: String, drainTimeout: DispatchTimeInterval
    ) -> Bool {
        guard let dir = serverDirectory(forPfx: pfx, root: root),
            FileManager.default.fileExists(atPath: dir.path(percentEncoded: false))
        else { return false }

        guard let result = try? Shell.run(
            lsof, ["-t", "+D", dir.path(percentEncoded: false)], drainTimeout: drainTimeout)
        else { return true }

        if !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }

        return result.outputLost || !result.stderr.isEmpty
    }
}

struct PrefixClaim {
    fileprivate let fd: Int32

    func release() {
        if fd >= 0 { FileLock.release(fd) }
    }
}
