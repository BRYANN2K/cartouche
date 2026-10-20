import CryptoKit
import Foundation

// Same requests as rcheevos (dorequest.php); the password goes out once, only the token is kept (keychain).

public struct AchievementsLogin: Sendable, Equatable {
    public var username: String
    public var token: String
    public var host: URL?

    public init(username: String, token: String, host: URL? = nil) {
        self.username = username
        self.token = token
        self.host = host
    }
}

public struct AchievementProgress: Codable, Sendable, Equatable {
    public var unlocked: Int
    public var unlockedHardcore: Int
    public var total: Int

    public init(unlocked: Int, unlockedHardcore: Int, total: Int) {
        self.unlocked = unlocked
        self.unlockedHardcore = unlockedHardcore
        self.total = total
    }
}

public enum AchievementsError: Error, Equatable, LocalizedError {
    // The server said no, with its reason: a wrong password, an expired token
    case refused(String)
    case unavailable(status: Int)

    public var errorDescription: String? {
        switch self {
        case .refused(let reason): reason
        case .unavailable(let status): String(localized: "RetroAchievements did not answer (\(status)).", bundle: .module)
        }
    }
}

public struct AchievementsClient: Sendable {

    public static let site = URL(string: "https://retroachievements.org/")!

    public typealias Post = @Sendable (URLRequest) async throws -> (Data, Int)

    public var host: URL
    private let post: Post

    public init(host: URL = AchievementsClient.site, post: Post? = nil) {
        self.host = host
        self.post = post ?? { request in
            let (data, response) = try await URLSession.shared.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    // The token for the account; the password goes out once, over HTTPS
    public func signIn(username: String, password: String) async throws -> AchievementsLogin {
        let reply = try await request([("r", "login2"), ("u", username), ("p", password)])
        guard let user = reply["User"] as? String, let token = reply["Token"] as? String, !token.isEmpty else {
            throw AchievementsError.refused(String(localized: "RetroAchievements gave no token.", bundle: .module))
        }
        return AchievementsLogin(username: user, token: token, host: host == Self.site ? nil : host)
    }

    public func gameID(hash: String) async throws -> Int? {
        let reply = try await request([("r", "gameid"), ("m", hash)])
        let id = (reply["GameID"] as? NSNumber)?.intValue ?? 0
        return id > 0 ? id : nil
    }

    public func progress(console: Int, login: AchievementsLogin) async throws -> [Int: AchievementProgress] {
        let reply = try await request([("r", "allprogress"), ("u", login.username), ("t", login.token), ("c", String(console))])
        var out: [Int: AchievementProgress] = [:]
        for (key, value) in reply["Response"] as? [String: Any] ?? [:] {
            guard let id = Int(key), let entry = value as? [String: Any] else { continue }
            func count(_ name: String) -> Int { (entry[name] as? NSNumber)?.intValue ?? 0 }
            out[id] = AchievementProgress(unlocked: count("Unlocked"), unlockedHardcore: count("UnlockedHardcore"),
                                          total: count("Achievements"))
        }
        return out
    }

    public func gameData(_ game: Int, login: AchievementsLogin) async throws -> (title: String, richPresence: String) {
        let reply = try await request([("r", "patch"), ("u", login.username), ("t", login.token), ("g", String(game))])
        let patch = reply["PatchData"] as? [String: Any] ?? [:]
        return (patch["Title"] as? String ?? "", patch["RichPresencePatch"] as? String ?? "")
    }

    private func request(_ fields: [(String, String)]) async throws -> [String: Any] {
        var request = URLRequest(url: host.appending(path: "dorequest.php"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        // RetroAchievements asks clients to name themselves
        request.setValue("Cartouche", forHTTPHeaderField: "User-Agent")
        request.httpBody = Data(Self.form(fields).utf8)
        let (data, status) = try await post(request)
        let reply = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if let reply, reply["Success"] as? Bool == false {
            throw AchievementsError.refused(reply["Error"] as? String ?? String(localized: "RetroAchievements refused the request.", bundle: .module))
        }
        guard status == 200, let reply else { throw AchievementsError.unavailable(status: status) }
        return reply
    }

    static func form(_ fields: [(String, String)]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&")
    }
}

// Disc consoles and the Nintendo 64 hash in ways only rcheevos does; their game is learned from RetroArch's log once played.
public enum AchievementsConsole {

    public static func id(_ console: String) -> Int? {
        [
            "genesis": 1, "n64": 2, "snes": 3, "gb": 4, "gba": 5, "gbc": 6, "nes": 7, "pce": 8,
            "mastersystem": 11, "ps1": 12, "gamegear": 15, "nds": 18, "atari2600": 25,
        ][console]
    }

    // At most the first 64 MiB, as rcheevos reads
    static let limit = 64 * 1024 * 1024

    public static func hash(of file: URL, console: String) -> String? {
        guard ["nes", "snes", "pce", "gb", "gbc", "gba", "genesis", "mastersystem", "gamegear", "atari2600"].contains(console),
              !["zip", "7z"].contains(file.pathExtension.lowercased()),
              let handle = try? FileHandle(forReadingFrom: file)
        else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: limit), !data.isEmpty else { return nil }
        var skip = 0
        switch console {
        case "nes":
            let magic = data.prefix(4)
            if data.count > 16, magic == Data("NES\u{1A}".utf8) || magic == Data("FDS\u{1A}".utf8) { skip = 16 }
        case "snes":
            if data.count % 0x2000 == 512 { skip = 512 }
        case "pce":
            if data.count & 512 != 0 { skip = 512 }
        default:
            break
        }
        return Insecure.MD5.hash(data: data.dropFirst(skip)).map { String(format: "%02x", $0) }.joined()
    }

    // The game RetroArch's rcheevos recognized, from its log:
    // "[RCHEEVOS]: Identified game: 1234 "Title" (hash)"
    public static func identifiedGame(in lines: [String]) -> Int? {
        for line in lines.reversed() {
            guard let range = line.range(of: "Identified game: ") else { continue }
            let digits = line[range.upperBound...].prefix { $0.isNumber }
            if let id = Int(digits), id > 0 { return id }
        }
        return nil
    }

    // "[RCHEEVOS]: Load started, hardcore active"
    public static func hardcoreReported(in lines: [String]) -> Bool? {
        for line in lines.reversed() where line.contains("Load started, hardcore") {
            return !line.contains("not active")
        }
        return nil
    }
}
