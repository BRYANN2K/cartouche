import CryptoKit
import Foundation
import Testing

@testable import RetroArchKit

// Recorded answers: what retroachievements.org's dorequest.php sends for each
// request, in the shape rcheevos reads (deps/rcheevos/src/rapi at the pinned
// commit), with a made-up account
enum RecordedAchievements {
    static let login = #"{"Success":true,"User":"player42","AvatarUrl":"https://media.retroachievements.org/UserPic/player42.png","Token":"Q1w2E3r4T5y6U7i8","Score":1250,"SoftcoreScore":40,"Messages":0,"Permissions":1,"AccountType":"Registered"}"#
    static let wrongPassword = #"{"Success":false,"Error":"Invalid User/Password combination. Please try again","Code":"invalid_credentials","Status":401}"#
    static let gameID = #"{"Success":true,"GameID":228}"#
    static let unknownHash = #"{"Success":true,"GameID":0}"#
    static let allProgress = #"{"Success":true,"Response":{"228":{"Achievements":64,"Unlocked":12,"UnlockedHardcore":7},"1446":{"Achievements":38,"Unlocked":38,"UnlockedHardcore":38}}}"#
    static let patch = #"{"Success":true,"PatchData":{"ID":228,"Title":"Cartouche Homebrew","ConsoleID":3,"ImageIcon":"/Images/000001.png","RichPresencePatch":"Lookup:Area\n0=Title\n1=Brinstar\n\nDisplay:\n@Area(0xH0d6c) - Lives @Number(0xH0032)","Achievements":[],"Leaderboards":[]}}"#
}

final class RecordedPost: @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [[String: String]] = []
    let answers: [String: String]

    init(_ answers: [String: String]) { self.answers = answers }

    var requests: [[String: String]] { lock.withLock { sent } }

    var post: AchievementsClient.Post {
        { [self] request in
            let fields = AchievementsServer.form(String(decoding: request.httpBody ?? Data(), as: UTF8.self))
            lock.withLock { sent.append(fields) }
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/dorequest.php")
            return (Data((answers[fields["r"] ?? ""] ?? #"{"Success":false,"Error":"?"}"#).utf8), 200)
        }
    }
}

@Suite("RetroAchievements")
struct AchievementsTests {

    @Test func signingInKeepsTheTokenAndSendsThePasswordOnce() async throws {
        let post = RecordedPost(["login2": RecordedAchievements.login])
        let client = AchievementsClient(post: post.post)
        let login = try await client.signIn(username: "player42", password: "correct horse")
        #expect(login == AchievementsLogin(username: "player42", token: "Q1w2E3r4T5y6U7i8"))
        #expect(post.requests == [["r": "login2", "u": "player42", "p": "correct horse"]])

        let wrong = AchievementsClient(post: RecordedPost(["login2": RecordedAchievements.wrongPassword]).post)
        await #expect(throws: AchievementsError.refused("Invalid User/Password combination. Please try again")) {
            try await wrong.signIn(username: "player42", password: "nope")
        }
    }

    @Test func countsAreTheSitesForTheAccount() async throws {
        let post = RecordedPost(["gameid": RecordedAchievements.gameID, "allprogress": RecordedAchievements.allProgress])
        let client = AchievementsClient(post: post.post)
        let login = AchievementsLogin(username: "player42", token: "Q1w2E3r4T5y6U7i8")
        #expect(try await client.gameID(hash: "0123456789abcdef0123456789abcdef") == 228)
        let all = try await client.progress(console: 3, login: login)
        #expect(all[228] == AchievementProgress(unlocked: 12, unlockedHardcore: 7, total: 64))
        #expect(all[1446]?.unlocked == 38)
        #expect(post.requests.last == ["r": "allprogress", "u": "player42", "t": "Q1w2E3r4T5y6U7i8", "c": "3"])
        let none = AchievementsClient(post: RecordedPost(["gameid": RecordedAchievements.unknownHash]).post)
        #expect(try await none.gameID(hash: "ffff") == nil)
    }

    @Test func cartridgesAreHashedAsRcheevosDoes() throws {
        let work = try scratchFolder("hash")
        defer { try? FileManager.default.removeItem(at: work) }
        func md5(_ data: Data) -> String { Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined() }
        let body = Data((0..<32768).map { UInt8($0 & 0xFF) })
        // NES: the 16-byte iNES header is left out
        let nes = work.appending(path: "game.nes")
        try (Data("NES\u{1A}".utf8) + Data(repeating: 0, count: 12) + body).write(to: nes)
        #expect(AchievementsConsole.hash(of: nes, console: "nes") == md5(body))
        // SNES: a 512-byte copier header is left out
        let snes = work.appending(path: "game.sfc")
        try (Data(repeating: 0xEE, count: 512) + body).write(to: snes)
        #expect(AchievementsConsole.hash(of: snes, console: "snes") == md5(body))
        let gb = work.appending(path: "game.gb")
        try body.write(to: gb)
        #expect(AchievementsConsole.hash(of: gb, console: "gb") == md5(body))
        // Discs and zips: learned from RetroArch's log instead
        #expect(AchievementsConsole.hash(of: gb, console: "ps1") == nil)
        #expect(AchievementsConsole.id("snes") == 3 && AchievementsConsole.id("ps1") == 12 && AchievementsConsole.id("nope") == nil)
    }

    @Test func retroArchsLogNamesTheGameAndHardcore() {
        let lines = ["[INFO] [RCHEEVOS]: Load started, hardcore active",
                     "[INFO] [RCHEEVOS]: Identified game: 4242 \"Cartouche Test\" (0123abcd)"]
        #expect(AchievementsConsole.identifiedGame(in: lines) == 4242)
        #expect(AchievementsConsole.hardcoreReported(in: lines) == true)
        #expect(AchievementsConsole.hardcoreReported(in: ["[RCHEEVOS]: Load started, hardcore not active"]) == false)
        #expect(AchievementsConsole.identifiedGame(in: ["nothing"]) == nil)
    }

    @Test func theTokenGoesToRetroArchAndIsTakenOutOnceRead() throws {
        var config = AppendConfig(paths: RetroArchPaths(root: URL(fileURLWithPath: "/tmp/ra")))
        func value(_ key: String, _ config: AppendConfig) -> String? { config.values.first { $0.0 == key }?.1 }
        #expect(value("cheevos_enable", config) == "false")
        config.achievements = AchievementsLogin(username: "player42", token: "Q1w2E3r4T5y6U7i8")
        #expect(value("cheevos_enable", config) == "true")
        #expect(value("cheevos_username", config) == "player42")
        #expect(value("cheevos_token", config) == "Q1w2E3r4T5y6U7i8")
        #expect(value("cheevos_password", config) == "")
        #expect(value("cheevos_token", config.withoutSecrets) == "")
        config.hardcore = true
        #expect(value("rewind_enable", config) == "false")
        #expect(value("cheevos_hardcore_mode_enable", config) == "true")
    }

    @Test func secretsAreScrubbedFromWhatRetroArchWroteBack() throws {
        let work = try scratchFolder("scrub")
        defer { try? FileManager.default.removeItem(at: work) }
        let paths = RetroArchPaths(root: work)
        var config = AppendConfig(paths: paths)
        config.achievements = AchievementsLogin(username: "player42", token: "Q1w2E3r4T5y6U7i8")
        try config.write()
        let mode = try FileManager.default.attributesOfItem(atPath: paths.appendConfig.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        try "video_driver = \"gl\"\ncheevos_token = \"Q1w2E3r4T5y6U7i8\"\ncheevos_username = \"player42\"\n"
            .write(to: paths.baseConfig, atomically: true, encoding: .utf8)
        try "sealed".write(to: work.appending(path: "retroarch-keychain.cfg"), atomically: true, encoding: .utf8)
        ConsolePlayer.scrubSecrets(in: paths)
        for file in [paths.baseConfig, paths.appendConfig] {
            #expect(!(try String(contentsOf: file, encoding: .utf8)).contains("Q1w2E3r4T5y6U7i8"), "\(file.lastPathComponent)")
        }
        #expect(try String(contentsOf: paths.baseConfig, encoding: .utf8).contains("video_driver = \"gl\""))
        #expect(!FileManager.default.fileExists(atPath: work.appending(path: "retroarch-keychain.cfg").path))
    }
}

@Suite("Console extras", .serialized)
@MainActor
struct ConsoleExtrasTests {

    func extras(_ work: URL, post: RecordedPost, drive: URL? = nil) -> (ConsoleExtras, MemorySecrets) {
        let secrets = MemorySecrets()
        let paths = RetroArchPaths(root: work.appending(path: "cartouche"))
        let extras = ConsoleExtras(paths: paths, client: AchievementsClient(post: post.post), secrets: secrets,
                                   cloud: CloudSaves(paths: paths, drive: drive ?? work.appending(path: "iCloud Drive")))
        return (extras, secrets)
    }

    func game(in work: URL, data: Data = Data((0..<32768).map { UInt8($0 & 0xFF) })) throws -> ConsoleGame {
        let file = work.appending(path: "Cartouche Homebrew.sfc")
        try data.write(to: file)
        return ConsoleGame(console: "snes", name: "Cartouche Homebrew", databaseName: "Cartouche Homebrew (World)",
                           file: file, identifiedBy: .checksum)
    }

    @Test func signInOnceThenCountsPerGame() async throws {
        let work = try scratchFolder("extras-sign-in")
        defer { try? FileManager.default.removeItem(at: work) }
        let post = RecordedPost(["login2": RecordedAchievements.login, "gameid": RecordedAchievements.gameID,
                                 "allprogress": RecordedAchievements.allProgress])
        let (extras, secrets) = extras(work, post: post)
        let game = try game(in: work)
        #expect(extras.login == nil && extras.progress(for: game) == nil)

        await extras.signIn(username: "player42", password: "correct horse")
        #expect(extras.username == "player42" && extras.problem == nil)
        // The token in the keychain, the password nowhere
        #expect(secrets.all == ["player42": "Q1w2E3r4T5y6U7i8"])
        let saved = try String(contentsOf: extras.file, encoding: .utf8)
        #expect(!saved.contains("correct horse") && !saved.contains("Q1w2E3r4T5y6U7i8"))

        await extras.refresh(game)
        #expect(extras.progress(for: game) == AchievementProgress(unlocked: 12, unlockedHardcore: 7, total: 64))
        #expect(extras.knownGameID(game) == 228)
        // The hash asked for is the cartridge's, its copier header left out
        let hash = try #require(post.requests.first { $0["r"] == "gameid" }?["m"])
        #expect(hash == AchievementsConsole.hash(of: game.fileURL, console: "snes"))
        let again = ConsoleExtras(paths: extras.paths, client: AchievementsClient(post: post.post), secrets: secrets)
        #expect(again.progress(for: game)?.unlocked == 12 && again.login?.token == "Q1w2E3r4T5y6U7i8")

        var request = PlayRequest(core: URL(fileURLWithPath: "/core"), content: game.fileURL)
        extras.apply(to: &request, game: game)
        #expect(request.achievements == AchievementsLogin(username: "player42", token: "Q1w2E3r4T5y6U7i8"))
        #expect(request.translation == nil)

        extras.signOut()
        #expect(secrets.all.isEmpty && extras.login == nil && extras.progress(for: game) == nil)
    }

    @Test func aWrongPasswordSaysWhy() async throws {
        let work = try scratchFolder("extras-wrong")
        defer { try? FileManager.default.removeItem(at: work) }
        let (extras, secrets) = extras(work, post: RecordedPost(["login2": RecordedAchievements.wrongPassword]))
        await extras.signIn(username: "player42", password: "nope")
        #expect(extras.username == nil && secrets.all.isEmpty)
        #expect(extras.problem == "Invalid User/Password combination. Please try again")
    }

    @Test func translationNeedsAServiceAndTheGamesChoice() throws {
        let work = try scratchFolder("extras-translate")
        defer { try? FileManager.default.removeItem(at: work) }
        let (extras, _) = extras(work, post: RecordedPost([:]))
        let game = try game(in: work)
        // No service: turning it on does nothing
        extras.setTranslate(true, for: game)
        #expect(!extras.translates(game))
        extras.setTranslationService("not a url")
        #expect(extras.translationService == nil)
        extras.setTranslationService(" http://192.168.1.5:4404/ ")
        #expect(extras.translationService == URL(string: "http://192.168.1.5:4404/"))
        extras.setTranslate(true, for: game)
        #expect(extras.translates(game))
        var request = PlayRequest(core: URL(fileURLWithPath: "/core"), content: game.fileURL)
        extras.apply(to: &request, game: game)
        let translation = try #require(request.translation)
        var config = AppendConfig(paths: extras.paths)
        config.translation = translation
        func value(_ key: String) -> String? { config.values.first { $0.0 == key }?.1 }
        #expect(value("ai_service_enable") == "true" && value("ai_service_url") == "http://192.168.1.5:4404/")
        #expect(value("ai_service_mode") == "0")
        #expect(TranslationSetup.language(Locale(identifier: "it_IT")) == 4)
        #expect(TranslationSetup.language(Locale(identifier: "zh-Hans")) == 13)
        #expect(TranslationSetup.language(Locale(identifier: "en_US")) == 1)
    }

    @Test func coachModeIsOffUntilTurnedOn() throws {
        let work = try scratchFolder("extras-coach")
        defer { try? FileManager.default.removeItem(at: work) }
        let (extras, _) = extras(work, post: RecordedPost([:]))
        let game = try game(in: work)
        #expect(!extras.coaches(game))
        extras.setCoach(true, for: game)
        #expect(extras.coaches(game))
        // An older extras.json, or none, reads
        #expect(try JSONDecoder().decode(ExtrasSettings.self, from: Data("{}".utf8)) == ExtrasSettings())
    }
}

// Saves and states in iCloud Drive: two Cartouche folders, as on two Macs,
// share one iCloud Drive folder that stands in for the synced one
@Suite("Saves in iCloud Drive", .serialized)
struct CloudSavesTests {

    @Test func aStateSavedOnOneMacIsListedOnTheOther() throws {
        let work = try scratchFolder("cloud")
        defer { try? FileManager.default.removeItem(at: work) }
        let drive = work.appending(path: "iCloud Drive", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
        let macA = RetroArchPaths(root: work.appending(path: "mac-a"))
        let macB = RetroArchPaths(root: work.appending(path: "mac-b"))

        let early = macA.states.appending(path: "Snes9x/Cartouche Homebrew.state1")
        try FileManager.default.createDirectory(at: early.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("slot 1".utf8).write(to: early)
        let a = CloudSaves(paths: macA, drive: drive), b = CloudSaves(paths: macB, drive: drive)
        #expect(a.isAvailable && !a.isOn)
        try a.turnOn()
        try b.turnOn()
        #expect(a.isOn && b.isOn)
        #expect(FileManager.default.fileExists(atPath: drive.appending(path: "Cartouche/States/Snes9x/Cartouche Homebrew.state1").path))

        // RetroArch on Mac A writes slot 3 with its picture, in its states folder
        let folder = macA.states.appending(path: "Snes9x", directoryHint: .isDirectory)
        try Data("slot 3".utf8).write(to: folder.appending(path: "Cartouche Homebrew.state3"))
        try Data("png".utf8).write(to: folder.appending(path: "Cartouche Homebrew.state3.png"))

        let onB = SaveStates.list(contentName: "Cartouche Homebrew", in: macB.states)
        #expect(Set(onB.compactMap(\.slot)) == [1, 3])
        #expect(onB.first { $0.slot == 3 }?.picture != nil)
        // The launch writes RetroArch's folders as before; they now lead to iCloud Drive
        var config = AppendConfig(paths: macB)
        try config.write()
        config.autoSaveState = true
        #expect(b.isOn)

        // Off again: Mac B keeps a copy of what was there
        try b.turnOff()
        #expect(!b.isOn)
        #expect(Set(SaveStates.list(contentName: "Cartouche Homebrew", in: macB.states).compactMap(\.slot)) == [1, 3])
    }

    @Test func iCloudDriveOffIsSaid() throws {
        let work = try scratchFolder("cloud-off")
        defer { try? FileManager.default.removeItem(at: work) }
        let cloud = CloudSaves(paths: RetroArchPaths(root: work.appending(path: "mac")), drive: work.appending(path: "missing"))
        #expect(!cloud.isAvailable)
        #expect(CloudSaves.iCloudDrive.path.hasSuffix("Library/Mobile Documents/com~apple~CloudDocs"))
    }
}

@Suite("Coach mode")
struct CoachTests {

    @Test func namedValuesComeFromTheRichPresenceScript() throws {
        let script = """
        Lookup:Area
        0=Title
        1=Brinstar
        2-3=Norfair
        *=Elsewhere

        Format:Score
        FormatType=VALUE

        Display:
        ?0xH0010=1?In the menu
        @Area(0xH0d6c) - Lives @Number(0xH0032) - Score @Score(0x 0040*10_0xH0042)
        """
        let values = RichPresence.values(in: script)
        #expect(values.map(\.name) == ["Area", "Number", "Score"])
        let area = values[0]
        #expect(area.terms.first?.address == 0x0D6C && area.terms.first?.size == .bits8)
        #expect(area.text(1) == "Brinstar" && area.text(3) == "Norfair" && area.text(9) == "Elsewhere")
        #expect(values[2].terms.count == 2 && values[2].terms[0].size == .bits16 && values[2].terms[0].multiplier == 10)
        #expect(AchievementsMemory.systemAddress(0x0D6C, console: "snes") == 0x7E0D6C)
        #expect(AchievementsMemory.systemAddress(0x0010, console: "genesis") == 0xFF0010)
        #expect(AchievementsMemory.systemAddress(0x0010, console: "nes") == 0x0010)
    }

    actor Game: CoachTarget {
        var memory: [Int: UInt8] = [0x7E0D6C: 1, 0x7E0032: 3]
        var pressed: [String] = []
        func readMemory(address: Int, bytes: Int) async throws -> [UInt8] { (0..<bytes).map { memory[address + $0] ?? 0 } }
        func press(player: Int, control: String, frames: Int) async throws -> String {
            pressed.append(control)
            return "PRESS \(player) \(control) \(frames)"
        }
    }

    @Test func inHardcoreReadingWorksAndPressingIsRefused() async throws {
        let game = Game()
        let values = RichPresence.values(in: "Lookup:Area\n1=Brinstar\n\nDisplay:\n@Area(0xH0d6c) @Lives(0xH0032)")
        let relay = CoachRelay(console: "snes", values: values, target: game, enabled: true) { true }
        let read = await relay.call("coach_read", ["name": "Area"])
        #expect(read["isError"] == .bool(false))
        #expect(read["content"]?.array?.first?["text"]?.string == "Area\t1\tBrinstar")
        let all = await relay.call("coach_values", [:])
        #expect(all["content"]?.array?.first?["text"]?.string == "Area\t1\tBrinstar\nLives\t3\t3")
        let press = await relay.call("coach_press", ["player": 1, "control": "a", "frames": 3])
        #expect(press["isError"] == .bool(true))
        #expect(press["content"]?.array?.first?["text"]?.string?.contains("Hardcore mode") == true)
        #expect(await game.pressed.isEmpty)
    }

    @Test func offByDefaultAndOutsideHardcoreItPresses() async throws {
        let game = Game()
        let values = RichPresence.values(in: "Display:\n@Lives(0xH0032)")
        let off = CoachRelay(console: "snes", values: values, target: game, enabled: false) { false }
        #expect(await off.call("coach_read", ["name": "Lives"])["isError"] == .bool(true))
        await off.setEnabled(true)
        #expect(try await off.read("Lives").value == 3)
        #expect(try await off.press(player: 1, control: "a", frames: 3) == "PRESS 1 a 3")
        await #expect(throws: CoachRefusal.unknownValue("Stage")) { try await off.read("Stage") }
        #expect(CoachRelay.tools.map(\.name) == ["coach_values", "coach_read", "coach_press"])
    }
}
