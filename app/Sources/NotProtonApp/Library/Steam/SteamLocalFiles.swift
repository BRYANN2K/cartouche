// What Steam keeps on disk about the signed-in account: who it is, which games are
// installed, when they were played, and the user's collections. Read when Steam is
// closed, and to fill in what the last import lacks.

import Foundation

struct SteamAccount: Equatable, Sendable {
    let steamID: String
    let accountName: String
    let personaName: String?

    // userdata/ folders are named by the 32-bit account ID
    var accountID: String? {
        guard let id = UInt64(steamID), id > Self.base else { return nil }
        return String(id - Self.base)
    }

    static let base: UInt64 = 76_561_197_960_265_728
}

struct SteamInstalledApp: Equatable, Sendable {
    let appID: Int
    let name: String
    let lastPlayed: Date?
}

struct SteamPlayData: Equatable, Sendable {
    var lastPlayed: Date?
    var playtimeMinutes: Int = 0
}

struct SteamCollection: Equatable, Sendable {
    let id: String
    let name: String
    let apps: [Int]
}

struct SteamLocalFiles: Sendable {

    // ~/Library/Application Support/Steam
    var userData: URL = SupportPaths.Steam.userData

    var libraryFolders: URL { userData.appending(path: "steamapps/libraryfolders.vdf") }
    var loginUsers: URL { userData.appending(path: "config/loginusers.vdf") }

    func account() -> SteamAccount? {
        guard let users = VDF.read(loginUsers)?["users"]?.entries, !users.isEmpty else { return nil }
        let pick = users.first { $0.1["MostRecent"]?.string == "1" }
            ?? users.max { ($0.1["Timestamp"]?.int ?? 0) < ($1.1["Timestamp"]?.int ?? 0) }
        guard let (id, user) = pick, let name = user["AccountName"]?.string, !name.isEmpty else { return nil }
        return SteamAccount(steamID: id, accountName: name, personaName: user["PersonaName"]?.string)
    }

    // Steam's own folder is always a library, even when the file is missing
    func libraries() -> [URL] {
        var roots = [userData]
        for (_, folder) in VDF.read(libraryFolders)?["libraryfolders"]?.entries ?? [] {
            if let path = folder["path"]?.string { roots.append(URL(filePath: path)) }
        }
        var seen: Set<String> = []
        return roots.filter {
            var path = $0.standardizedFileURL.path(percentEncoded: false)
            while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
            return seen.insert(path).inserted
        }
    }

    // Fully installed apps, StateFlags bit 4. Tools Steam installs for itself are left out.
    func installed() -> [SteamInstalledApp] {
        var apps: [Int: SteamInstalledApp] = [:]
        for library in libraries() {
            let steamapps = library.appending(path: "steamapps")
            let files = (try? FileManager.default.contentsOfDirectory(atPath: steamapps.path(percentEncoded: false))) ?? []
            for file in files where file.hasPrefix("appmanifest_") && file.hasSuffix(".acf") {
                guard let state = VDF.read(steamapps.appending(path: file))?["AppState"],
                      let appID = state["appid"]?.int,
                      let name = state["name"]?.string,
                      let flags = state["StateFlags"]?.int, flags & 4 != 0,
                      !Self.isTool(appID: appID, name: name)
                else { continue }
                apps[appID] = SteamInstalledApp(appID: appID, name: name, lastPlayed: Self.date(state["LastPlayed"]?.int))
            }
        }
        return apps.values.sorted { $0.appID < $1.appID }
    }

    // steamapps/common/<installdir> of an installed app
    func installFolder(appID: Int) -> URL? {
        for library in libraries() {
            let steamapps = library.appending(path: "steamapps")
            guard let dir = VDF.read(steamapps.appending(path: "appmanifest_\(appID).acf"))?[path: "AppState", "installdir"]?.string
            else { continue }
            let folder = steamapps.appending(path: "common").appending(path: dir)
            if FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)) { return folder }
        }
        return nil
    }

    func userFolder(_ account: SteamAccount) -> URL? {
        account.accountID.map { userData.appending(path: "userdata/\($0)") }
    }

    func playData(_ account: SteamAccount) -> [Int: SteamPlayData] {
        guard let folder = userFolder(account),
              let apps = VDF.read(folder.appending(path: "config/localconfig.vdf"))?[
                path: "UserLocalConfigStore", "Software", "Valve", "Steam", "apps"]
        else { return [:] }
        var out: [Int: SteamPlayData] = [:]
        for (key, app) in apps.entries {
            guard let appID = Int(key) else { continue }
            let data = SteamPlayData(lastPlayed: Self.date(app["LastPlayed"]?.int), playtimeMinutes: app["Playtime"]?.int ?? 0)
            if data.lastPlayed != nil || data.playtimeMinutes > 0 { out[appID] = data }
        }
        return out
    }

    // The user's own collections, from Steam's cloud storage file. Favorites and
    // hidden are Steam's built-in collections; dynamic ones have no fixed list.
    func collections(_ account: SteamAccount) -> [SteamCollection] {
        guard let folder = userFolder(account),
              let data = try? Data(contentsOf: folder.appending(path: "config/cloudstorage/cloud-storage-namespace-1.json")),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[Any]]
        else { return [] }
        var out: [SteamCollection] = []
        for row in rows {
            guard row.count == 2, let key = row[0] as? String, key.hasPrefix("user-collections."),
                  let entry = row[1] as? [String: Any], entry["is_deleted"] as? Bool != true,
                  let text = entry["value"] as? String,
                  let value = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  let id = value["id"] as? String, id != "favorite", id != "hidden",
                  let name = value["name"] as? String,
                  let added = value["added"] as? [Int]
            else { continue }
            let removed = Set(value["removed"] as? [Int] ?? [])
            out.append(SteamCollection(id: id, name: name, apps: added.filter { !removed.contains($0) }))
        }
        return out.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func date(_ unix: Int?) -> Date? {
        guard let unix, unix > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(unix))
    }

    // Runtimes and redistributables Steam installs on its own
    static let toolIDs: Set<Int> = [228_980, 1_070_560, 1_391_110, 1_628_350, 1_493_710, 1_826_330, 1_161_040]

    static func isTool(appID: Int, name: String) -> Bool {
        toolIDs.contains(appID) || name.hasPrefix("Proton ") || name.hasPrefix("Steam Linux Runtime")
            || name.hasPrefix("Steamworks Common")
    }
}
