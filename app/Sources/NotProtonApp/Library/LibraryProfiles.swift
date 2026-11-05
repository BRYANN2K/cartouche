import Foundation
import InstallerKit

// The game's one profile, read by the page, the launch and the in-game menu
extension LibraryModel {
    func profile(for id: String) -> OverlaySettings {
        _ = profileRevision
        if let cached = profileCache[id] { return cached }
        let loaded = profiles.profile(for: id) ?? OverlaySettings()
        profileCache[id] = loaded
        return loaded
    }

    // Saved, then the launch files follow: Steam's environment, an installer game's launcher
    func setProfile(_ settings: OverlaySettings, for id: String) {
        guard settings != profile(for: id) else { return }
        do {
            try profiles.save(settings, for: id)
        } catch {
            problem = String(localized: "Cartouche couldn’t save your library choices: \(error.localizedDescription)")
            return
        }
        profileCache[id] = settings
        profileRevision += 1
        setSetup(setup(for: id), for: id)
    }

    // The in-game menu saved the profile itself; its old launch variables leave the setup
    func profileSaved(_ id: String) {
        profileCache[id] = nil
        profileRevision += 1
        guard game(id) != nil else { return }
        var choice = setup(for: id)
        if let env = choice.environment {
            let kept = env.filter { !OverlayLaunch.variables.contains($0.key) }
            choice.environment = kept.isEmpty ? nil : kept
        }
        setSetup(choice, for: id)
    }

    func launchProfile(for game: Game) -> LaunchProfile {
        // A folder not yet scanned counts as protected: nothing of ours loads until it proves clean
        let scan = folderScan(for: game)
        let unproven = scan == nil && folderForScan(of: game) != nil
        let protected = antiCheat(game) != nil || scan?.antiCheat != nil || scan?.complete == false || unproven
            || antiCheatUnknown(game)
        return LaunchProfile(settings: profile(for: game.id), protected: protected, dlss: scan?.dlss ?? false)
    }

    // A Ubisoft game the base cannot name is unknown, never clean: it fails closed like a pending scan
    func antiCheatUnknown(_ game: Game) -> Bool {
        game.source == .ubisoft && (antiCheat(game) ?? folderScan(for: game)?.antiCheat) == nil
    }

    // The name the page, the consent sheet and the in-game menu all show: the compat base's or the folder's
    func antiCheatName(for game: Game) -> String? {
        let scan = folderScan(for: game)
        if let name = antiCheat(game) ?? scan?.antiCheat { return name }
        // A walk that could not finish proves nothing either way: the generic name, like a pending
        // scan — and a Ubisoft game without a match is unknown, never "no anti-cheat".
        return scan?.complete == false || game.source == .ubisoft ? ot("Anti-cheat") : nil
    }

    // Read once from the installed game's folder
    func shipsDLSS(_ game: Game) -> Bool {
        folderScan(for: game)?.dlss ?? false
    }

    // What one walk of the game's folder found, resolved on the actor; a miss starts the walk detached
    func folderScan(for game: Game) -> GameDiskScan? {
        if let scan = folderScans[game.id] { return scan }
        if scanning[game.id] == nil, !scanRequests.contains(game.id), folderForScan(of: game) != nil {
            scanRequests.insert(game.id)
            Task { await scanGames([game]) }
        }
        return nil
    }

    // The folder the walk covers: the record's game root, else the install folder's own answer
    private func folderForScan(of game: Game) -> URL? {
        if let folder = scanTargets[game.id] { return folder }
        let folder = scanFolder(of: game)
        if let folder { scanTargets[game.id] = folder }
        return folder
    }

    // Resolved fresh each time so Play can catch a moved install the cached target would miss
    private func scanFolder(of game: Game) -> URL? {
        var folder = installFolder(of: game)
        if game.source == .installer, let gameFolder = GameFolder.of(game, in: installsFolder),
           let record = InstalledGames.record(in: gameFolder) {
            folder = record.gameRoot
        }
        return folder
    }

    // A launch waits only while the walk can still answer: it answered this folder, unchanged since —
    // a moved install or a touched build evicts the cache and walks again before writing
    func scanPending(for game: Game) -> Bool {
        let folder = scanFolder(of: game)
        if folder != scanTargets[game.id] {
            folderScans[game.id] = nil
            scanTargets[game.id] = folder
        }
        if let folder, let scan = folderScans[game.id],
           scan.stamp != GameDiskScan.stamp(appID: game.steamAppID, of: folder) {
            folderScans[game.id] = nil
        }
        return folderScans[game.id] == nil && folder != nil
    }

    // The one walk per game, detached, whose answer a launch awaits before writing its variables
    func scanGames(_ games: [Game]) async {
        await scan(games.compactMap { game in folderForScan(of: game).map { (id: game.id, folder: $0) } })
    }

    // A folder the model cannot locate itself — a store's install record — is scanned under the game's id
    func scan(_ targets: [(id: String, folder: URL)]) async {
        // The walk's answer only stands for the folder it saw: moved or touched, it walks again
        for target in targets {
            if let scan = folderScans[target.id],
               scanTargets[target.id] != target.folder
                || scan.stamp != GameDiskScan.stamp(appID: game(target.id)?.steamAppID, of: target.folder) {
                folderScans[target.id] = nil
            }
            scanTargets[target.id] = target.folder
        }
        for target in targets where folderScans[target.id] == nil && scanning[target.id] == nil {
            let scan = folderScanner, appID = game(target.id)?.steamAppID
            // The stamp reads before the walk starts: a folder touched mid-walk fails the cache check
            scanning[target.id] = Task.detached {
                let stamp = GameDiskScan.stamp(appID: appID, of: target.folder)
                var result = scan(target.folder)
                result.stamp = stamp
                return result
            }
        }
        for target in targets where folderScans[target.id] == nil {
            guard let task = scanning[target.id] else { continue }
            let result = await task.value
            scanning[target.id] = nil
            scanRequests.remove(target.id)
            // A walk started before the install moved is not this folder's answer
            guard scanTargets[target.id] == nil || scanTargets[target.id] == target.folder else { continue }
            scanTargets[target.id] = target.folder
            folderScans[target.id] = result
        }
    }

    // What the launch actually wrote: the in-game HUD's native stand-in keys on the library's presence
    func noteLaunch(of game: Game, environment: [String: String]) {
        framegenLaunched[game.id] = environment[FrameGeneration.variable] == "1"
    }

    // Old Advanced switches move into the profile once; later writes of them (the agent, a fix) fold in too
    func absorbLegacy(_ choice: GameSetupChoice, for id: String) -> GameSetupChoice {
        guard GameProfile.hasLegacy(choice) else { return choice }
        let existing = profiles.profile(for: id)
        let migrated = GameProfile.migrated(choice, onto: existing ?? OverlaySettings(), first: existing == nil)
        do {
            try profiles.save(migrated, for: id)
            profileCache[id] = migrated
            profileRevision += 1
        } catch {
            AppLog.note("profile not migrated for \(id): \(error.localizedDescription)")
            return choice
        }
        return GameProfile.cleared(choice)
    }

    func migrateProfiles() {
        var changed = false
        for (id, choice) in choices.setups where GameProfile.hasLegacy(choice) || (choice.advanced != nil && profiles.profile(for: id) == nil) {
            let existing = profiles.profile(for: id)
            let migrated = GameProfile.migrated(choice, onto: existing ?? OverlaySettings(), first: existing == nil)
            guard (try? profiles.save(migrated, for: id)) != nil else { continue }
            replaceChoice(GameProfile.cleared(choice), for: id)
            changed = true
        }
        if changed { AppLog.note("game profiles: Advanced switches moved into each game's profile") }
    }
}
