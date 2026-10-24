import Foundation

// RetroArch does the netplay; there is no Cartouche server and no room code.

public enum NetplayRole: Sendable, Equatable {
    // Hosts on the port; with announce, the game is listed in libretro's lobby
    case host(port: UInt16, announce: Bool)
    case join(NetplayTarget)

    public static let defaultPort: UInt16 = 55435
}

public struct NetplayTarget: Sendable, Equatable, Hashable {
    public var address: String
    public var port: UInt16
    // A session on libretro's relay, when the host plays through it
    public var session: String?

    public init(address: String, port: UInt16, session: String? = nil) {
        self.address = address
        self.port = port
        self.session = session
    }
}

public struct NetplayRoom: Sendable, Equatable, Identifiable {
    public enum Origin: String, Sendable { case lobby, localNetwork }

    public var nickname: String
    // The loaded file's name without its extension, as RetroArch announces it
    public var gameName: String
    public var gameCRC: UInt32?
    // The core's own name: "Snes9x", "Genesis Plus GX"
    public var coreName: String
    public var coreVersion: String
    public var target: NetplayTarget
    public var hasPassword: Bool
    public var origin: Origin

    public init(nickname: String, gameName: String, gameCRC: UInt32?, coreName: String, coreVersion: String,
                target: NetplayTarget, hasPassword: Bool, origin: Origin) {
        self.nickname = nickname
        self.gameName = gameName
        self.gameCRC = gameCRC
        self.coreName = coreName
        self.coreVersion = coreVersion
        self.target = target
        self.hasPassword = hasPassword
        self.origin = origin
    }

    public var id: String { "\(origin.rawValue):\(target.address):\(target.port):\(target.session ?? "")" }

    public func core(for console: Console) -> String? {
        console.cores.first { ConsoleCatalog.coreName($0).caseInsensitiveCompare(coreName) == .orderedSame }
    }

    // A library game is this room's when the console's cores include the room's and the file matches by name or checksum.
    public func matches(_ game: ConsoleGame, console: Console, crc: UInt32? = nil) -> Bool {
        guard console.id == game.console, core(for: console) != nil else { return false }
        if let gameCRC, let crc, gameCRC != 0 { return gameCRC == crc }
        let name = gameName.lowercased()
        return name == game.contentName.lowercased() || name == game.databaseName?.lowercased()
    }
}

// The lobby list is served over plain HTTP only.
public struct NetplayLobby: Sendable {

    public static let libretro = URL(string: "http://lobby.libretro.com/")!

    public typealias Fetch = @Sendable (URL) async throws -> (Data, Int)

    public enum Problem: Error, Equatable {
        case unavailable(status: Int)
    }

    public var base: URL
    private let fetch: Fetch

    public init(base: URL = NetplayLobby.libretro, fetch: Fetch? = nil) {
        self.base = base
        self.fetch = fetch ?? { url in
            let (data, response) = try await URLSession.shared.data(from: url)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    public func rooms() async throws -> [NetplayRoom] {
        let (data, status) = try await fetch(base.appending(path: "list"))
        guard status == 200 else { throw Problem.unavailable(status: status) }
        return Self.rooms(from: data)
    }

    // The lobby's JSON: an array of {"fields": {...}}, one per hosted game
    public static func rooms(from data: Data) -> [NetplayRoom] {
        guard let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return entries.compactMap { entry in
            guard let fields = entry["fields"] as? [String: Any] else { return nil }
            func string(_ key: String) -> String { fields[key] as? String ?? "" }
            func int(_ key: String) -> Int { (fields[key] as? NSNumber)?.intValue ?? Int(string(key)) ?? 0 }
            // host_method 3: the host plays through libretro's relay, which anyone can reach; otherwise its own address and port.
            let relayed = int("host_method") == 3 && !string("mitm_ip").isEmpty && int("mitm_port") > 0
            let target = relayed
                ? NetplayTarget(address: string("mitm_ip"), port: UInt16(clamping: int("mitm_port")),
                                session: string("mitm_session").isEmpty ? nil : string("mitm_session"))
                : NetplayTarget(address: string("ip"), port: UInt16(clamping: int("port")))
            guard !target.address.isEmpty, target.port > 0 else { return nil }
            return NetplayRoom(
                nickname: string("username"), gameName: string("game_name"),
                gameCRC: UInt32(string("game_crc"), radix: 16), coreName: string("core_name"),
                coreVersion: string("core_version"), target: target,
                hasPassword: fields["has_password"] as? Bool ?? false, origin: .lobby)
        }
    }
}

// RetroArch publishes a hosted game on Bonjour as _ra_netplay._tcp, with the lobby fields in its TXT record.
public enum LocalNetplay {

    public static let serviceType = "_ra_netplay._tcp"

    public static func room(txt: [String: String], address: String, port: UInt16) -> NetplayRoom? {
        guard !address.isEmpty, port > 0 else { return nil }
        // RetroArch writes the checksum byte-swapped: %08x of htonl(crc)
        let crc = txt["content_crc"].flatMap { UInt32($0, radix: 16) }.map { $0.byteSwapped }
        return NetplayRoom(
            nickname: txt["nick"] ?? "", gameName: txt["content"] ?? "", gameCRC: crc,
            coreName: txt["core"] ?? "", coreVersion: txt["core_version"] ?? "",
            target: NetplayTarget(address: address, port: port),
            hasPassword: txt["has_password"] == "1" || txt["has_password"] == "true", origin: .localNetwork)
    }
}
