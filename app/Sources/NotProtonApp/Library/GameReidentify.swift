//// Records written before the identification pipeline kept the dropped folder's
//// name. On library load the same pipeline runs once over the raw-looking ones:
//// a confident match renames the record itself, a weaker answer is offered in the
//// panel as "Identified as …?", and a name the user set is never touched.

import Foundation
import InstallerKit

extension LibraryModel {

    // The import sheet's identification run again on an installed record: the
    // game's own files answer GOG info, engine metadata and a Steam app ID; the
    // compatibility index vouches for a name; the store search is asked only
    // when the online-lookups choice allows it — the same rules as the drop.
    func reidentifyInstalledGames(index: GameIndex, lookup: SteamLookup, allowed: Bool) async {
        var changed = false
        var suggestions: [String: String] = [:]
        for var record in InstalledGames.all(in: installsFolder)
        where record.userNamed != true && GameName.looksRaw(record.name) {
            let root = record.gameRoot
            guard FileManager.default.fileExists(atPath: root.path(percentEncoded: false)) else { continue }
            let id = await reidentify(record, root: root, index: index, lookup: lookup, allowed: allowed)
            let folder = GameFolder.of(slug: record.id, in: installsFolder)
            if let match = id.match {
                record.name = match.name
                record.appID = match.appID
                record.gogID = record.gogID ?? id.gogID
                do {
                    try InstalledGames.save(record, in: folder)
                    changed = true
                } catch {
                    AppLog.note("could not re-identify \(record.id): \(error.localizedDescription)")
                }
            } else if !id.name.isEmpty, id.name != record.name {
                suggestions["installer:\(record.id)"] = id.name
            }
        }
        nameSuggestions = suggestions
        if changed { showInstalledGames(InstalledGames.all(in: installsFolder)) }
    }

    private func reidentify(
        _ record: InstalledGame, root: URL, index: GameIndex, lookup: SteamLookup, allowed: Bool
    ) async -> GameIdentification {
        let exe = record.exeURL
        let (hints, gog) = await Task.detached {
            (EngineMetadata.hints(in: root, exe: exe), GOGInfo.find(in: root)?.info)
        }.value
        var id = GameIdentification.identify(
            gog: gog, steamAppID: hints.steamAppID,
            engineInfo: hints.name, productName: hints.productName ?? PEVersion.productName(of: exe),
            exeName: hints.exeName, innerFolder: hints.innerFolder,
            folderName: record.name, index: index
        )
        if id.match == nil, allowed {
            for (source, name) in GameIdentification.orderedCandidates(
                gog: gog, engineInfo: hints.name, productName: hints.productName,
                exeName: hints.exeName, innerFolder: hints.innerFolder, folderName: record.name
            ) {
                if let hit = await lookup.match(for: name) {
                    id = GameIdentification(
                        name: hit.name, source: source,
                        match: GameIndex.Entry(appID: hit.appID, name: hit.name), gogID: id.gogID
                    )
                    break
                }
            }
        }
        return id
    }

    // The menu's Rename and the panel's accept both land here: the record's name
    // becomes the user's own, so the re-identification pass leaves it alone.
    func rename(_ game: Game, to name: String) {
        guard let folder = GameFolder.of(game, in: installsFolder),
              var record = InstalledGames.record(in: folder) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        record.name = trimmed
        record.userNamed = true
        do {
            try InstalledGames.save(record, in: folder)
            nameSuggestions[game.id] = nil
            showInstalledGames(InstalledGames.all(in: installsFolder))
        } catch {
            problem = String(localized: "Cartouche couldn’t rename \(game.name): \(error.localizedDescription)")
        }
    }
}
