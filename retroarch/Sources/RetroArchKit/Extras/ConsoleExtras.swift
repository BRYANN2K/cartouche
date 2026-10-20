import Foundation
import Observation

// extras.json holds no secret: the RetroAchievements token is in the keychain.
public struct ExtrasSettings: Codable, Sendable, Equatable {
    public var username: String?
    public var translationService: String?
    public var netplayNickname: String?
    public var cloudSaves = false
    public var translate: Set<String> = []
    public var coach: Set<String> = []
    // The RetroAchievements game of each library game, once known
    public var gameIDs: [String: Int] = [:]
    public var progress: [String: AchievementProgress] = [:]

    public init() {}

    enum CodingKeys: String, CodingKey {
        case username, translationService, netplayNickname, cloudSaves, translate, coach, gameIDs, progress
    }

    // Every key may be missing, so a file from an older Cartouche still reads
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        username = try c.decodeIfPresent(String.self, forKey: .username)
        translationService = try c.decodeIfPresent(String.self, forKey: .translationService)
        netplayNickname = try c.decodeIfPresent(String.self, forKey: .netplayNickname)
        cloudSaves = try c.decodeIfPresent(Bool.self, forKey: .cloudSaves) ?? false
        translate = try c.decodeIfPresent(Set<String>.self, forKey: .translate) ?? []
        coach = try c.decodeIfPresent(Set<String>.self, forKey: .coach) ?? []
        gameIDs = try c.decodeIfPresent([String: Int].self, forKey: .gameIDs) ?? [:]
        progress = try c.decodeIfPresent([String: AchievementProgress].self, forKey: .progress) ?? [:]
    }
}

@MainActor
@Observable
public final class ConsoleExtras {

    public static let keychainService = "dev.bryann2k.cartouche.retroachievements"

    public let paths: RetroArchPaths
    public private(set) var settings: ExtrasSettings
    public private(set) var working = false
    public var problem: String?

    @ObservationIgnored public let client: AchievementsClient
    @ObservationIgnored public let secrets: any SecretStore
    @ObservationIgnored public var cloud: CloudSaves
    // Read once from the keychain, so it is not asked at every launch
    @ObservationIgnored private var token: String?
    // Toggling cloud saves moves the folders RetroArch reads, so it is refused while a game plays.
    @ObservationIgnored public var isPlaying: @Sendable () -> Bool = { false }

    public init(paths: RetroArchPaths, client: AchievementsClient = AchievementsClient(),
                secrets: any SecretStore = KeychainSecrets(service: ConsoleExtras.keychainService),
                cloud: CloudSaves? = nil) {
        self.paths = paths
        self.client = client
        self.secrets = secrets
        self.cloud = cloud ?? CloudSaves(paths: paths)
        settings = Self.load(paths)
    }

    public var file: URL { paths.root.appending(path: "extras.json") }

    // MARK: RetroAchievements

    public var username: String? { settings.username }

    public var login: AchievementsLogin? {
        guard let username = settings.username else { return nil }
        if token == nil { token = secrets.read(username) }
        guard let token, !token.isEmpty else { return nil }
        return AchievementsLogin(username: username, token: token,
                                 host: client.host == AchievementsClient.site ? nil : client.host)
    }

    // The password goes to RetroAchievements once; only the token is kept
    public func signIn(username: String, password: String) async {
        problem = nil
        working = true
        defer { working = false }
        do {
            let login = try await client.signIn(username: username, password: password)
            try secrets.write(login.token, for: login.username)
            token = login.token
            change { $0.username = login.username }
        } catch {
            problem = error.localizedDescription
        }
    }

    public func signOut() {
        if let username = settings.username { secrets.delete(username) }
        token = nil
        change {
            $0.username = nil
            $0.progress = [:]
        }
    }

    public func progress(for game: ConsoleGame) -> AchievementProgress? {
        settings.username == nil ? nil : settings.progress[game.id]
    }

    public func knownGameID(_ game: ConsoleGame) -> Int? { settings.gameIDs[game.id] }

    // The RetroAchievements game is found by the cartridge's hash, or as RetroArch's log named it.
    public func refresh(_ game: ConsoleGame) async {
        guard let login, let console = AchievementsConsole.id(game.console) else { return }
        do {
            var id = settings.gameIDs[game.id]
            if id == nil, let hash = await Self.hash(game) {
                id = try await client.gameID(hash: hash)
                if let id { change { $0.gameIDs[game.id] = id } }
            }
            guard let id else { return }
            let all = try await client.progress(console: console, login: login)
            let progress = all[id] ?? AchievementProgress(unlocked: 0, unlockedHardcore: 0, total: settings.progress[game.id]?.total ?? 0)
            change { $0.progress[game.id] = progress }
        } catch AchievementsError.refused(let reason) {
            problem = reason
        } catch {
            // Offline: the last counts stay
        }
    }

    // RetroArch's log names the game rcheevos recognized
    public func learn(gameID: Int, for game: ConsoleGame) {
        guard settings.gameIDs[game.id] != gameID else { return }
        change { $0.gameIDs[game.id] = gameID }
    }

    nonisolated static func hash(_ game: ConsoleGame) async -> String? {
        await Task.detached(priority: .utility) { AchievementsConsole.hash(of: game.fileURL, console: game.console) }.value
    }

    // MARK: Translation, netplay, coach

    public var translationService: URL? { settings.translationService.flatMap(TranslationSetup.service) }

    public func setTranslationService(_ text: String) {
        let url = TranslationSetup.service(text)
        change { $0.translationService = url?.absoluteString }
    }

    public func translates(_ game: ConsoleGame) -> Bool {
        translationService != nil && settings.translate.contains(game.id)
    }

    public func setTranslate(_ on: Bool, for game: ConsoleGame) {
        guard translationService != nil else { return }
        change { if on { $0.translate.insert(game.id) } else { $0.translate.remove(game.id) } }
    }

    public func coaches(_ game: ConsoleGame) -> Bool { settings.coach.contains(game.id) }

    public func setCoach(_ on: Bool, for game: ConsoleGame) {
        change { if on { $0.coach.insert(game.id) } else { $0.coach.remove(game.id) } }
    }

    // The chosen name, else the RetroAchievements name, else RetroArch's default. Never the Mac's account name.
    public var netplayNickname: String? {
        settings.netplayNickname ?? settings.username
    }

    public func setNetplayNickname(_ name: String) {
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(31))
        change { $0.netplayNickname = trimmed.isEmpty ? nil : trimmed }
    }

    // MARK: iCloud Drive

    public var cloudSaves: Bool { settings.cloudSaves }

    public func setCloudSaves(_ on: Bool) async {
        problem = nil
        guard !isPlaying() else {
            problem = String(localized: "Quit the game first to change this setting.", bundle: .module)
            return
        }
        let cloud = cloud
        do {
            if on {
                let available = await Task.detached { cloud.isAvailable }.value
                guard available else {
                    problem = String(localized: "iCloud Drive is off on this Mac. Turn it on in System Settings, then try again.", bundle: .module)
                    return
                }
                try await Task.detached { try cloud.turnOn() }.value
            } else {
                try await Task.detached { try cloud.turnOff() }.value
            }
            change { $0.cloudSaves = on }
        } catch {
            problem = error.localizedDescription
        }
    }

    // MARK: What a launch takes from here

    public func apply(to request: inout PlayRequest, game: ConsoleGame) {
        request.achievements = login
        request.netplayNickname = netplayNickname
        if translates(game), let service = translationService {
            request.translation = TranslationSetup(service: service, targetLanguage: TranslationSetup.language())
        }
    }

    private func change(_ edit: (inout ExtrasSettings) -> Void) {
        edit(&settings)
        try? FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(settings).write(to: file, options: .atomic)
    }

    private static func load(_ paths: RetroArchPaths) -> ExtrasSettings {
        (try? Data(contentsOf: paths.root.appending(path: "extras.json")))
            .flatMap { try? JSONDecoder().decode(ExtrasSettings.self, from: $0) } ?? ExtrasSettings()
    }
}
