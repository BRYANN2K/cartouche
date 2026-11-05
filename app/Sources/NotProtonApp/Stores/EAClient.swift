// The EA app's adopted session and its private owned-games API. Sign-in runs inside the
// real launcher — its OAuth is PKCE S256 ending on qrc:///html/login_successful.html, a
// page only its own CEF reaches (B7) — so the session probe adopts the token the launcher
// leaves, and the only grant still ours is refresh_token. The token lives only in the
// vault (token.json, one file) and is never logged. Endpoint, operation and field names
// are the launcher's own — private and unversioned; fixtures cover them in tests and the
// risks are listed in docs/research/release-0.2.0-beta2/stores-model.md.

import Foundation

// The HTTP channel the client talks over; tests answer it with fixtures.
protocol EAHTTP: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionHTTP: EAHTTP {
    let session: URLSession
    init(_ session: URLSession = URLSession(configuration: .ephemeral)) { self.session = session }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw StoreError.failed(String(localized: "EA answered without an HTTP response."))
        }
        return (data, http)
    }
}

// The session as the vault keeps it: token.json is the only EA file it holds.
struct EAToken: Codable, Equatable, Sendable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var refreshExpiresAt: Date?

    func expired(at now: Date) -> Bool { expiresAt <= now }

    // Adoptable: a live access token, or a refresh window still open to mint one.
    func live(at now: Date) -> Bool { expiresAt > now || (refreshExpiresAt ?? .distantPast) > now }

    func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    static func read(_ data: Data) -> EAToken? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(EAToken.self, from: data)
    }
}

// accounts.ea.com's token endpoint — the only grant still ours: refresh_token on an
// adopted session. The authorize half is the launcher's own (B7: PKCE, redirect
// qrc:///html/login_successful.html) and can't be replayed from a WebView or loopback.
struct EAAuthFlow: Sendable {
    var http: any EAHTTP = URLSessionHTTP()
    // The launcher client's public OAuth id; a secret is provisioned separately, never here.
    var clientID = "JUNO_PC_CLIENT"
    var clientSecret: String? = nil
    var tokenURL = URL(string: "https://accounts.ea.com/connect/token")!
    var now: @Sendable () -> Date = { Date() }

    func refresh(_ token: EAToken) async throws -> EAToken {
        try await grant(["grant_type": "refresh_token", "refresh_token": token.refreshToken])
    }

    // Form values encoded the strict way: unreserved characters only, so : and / are %XX.
    private static let formCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private func grant(_ fields: [String: String]) async throws -> EAToken {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        var fields = fields
        fields["client_id"] = clientID
        if let clientSecret { fields["client_secret"] = clientSecret }
        request.httpBody = fields.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: Self.formCharacters) ?? $0.value)" }
            .joined(separator: "&").data(using: .utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await http.send(request)
        switch response.statusCode {
        case 200:
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let access = json["access_token"] as? String, !access.isEmpty else {
                throw StoreError.failed(String(localized: "EA answered without a session token."))
            }
            let at = now()
            let seconds = { (key: String) -> TimeInterval? in
                (json[key] as? NSNumber).map(\.doubleValue) ?? (json[key] as? String).flatMap(TimeInterval.init)
            }
            return EAToken(accessToken: access,
                           refreshToken: (json["refresh_token"] as? String) ?? "",
                           expiresAt: at.addingTimeInterval(seconds("expires_in") ?? 0),
                           refreshExpiresAt: seconds("refresh_expires_in").map { at.addingTimeInterval($0) })
        case 400, 401, 403:
            throw StoreError.sessionExpired
        default:
            throw StoreError.failed(String(localized: "EA answered \(response.statusCode)."))
        }
    }
}

// service-aggregation-layer's GraphQL: the same operation the launcher uses.
struct EALibrary: Sendable {
    var http: any EAHTTP = URLSessionHTTP()
    var endpoint = URL(string: "https://service-aggregation-layer.juno.ea.com/graphql")!
    var pageSize = 50

    private struct Envelope: Decodable { let data: Data_? }
    private struct Data_: Decodable { let me: Me? }
    private struct Me: Decodable {
        let player: Player?
        let ownedGameProducts: Page?
        // For getLegacyEntitlements, `me` itself is the page
        let items: [LegacyItem]?
        let next: String?
    }
    private struct Player: Decodable { let displayName: String? }
    private struct Page: Decodable {
        let next: String?
        let items: [Item]?
    }
    private struct Item: Decodable {
        let id, originOfferId, status: String?
        let product: Product?
    }
    private struct Product: Decodable {
        let name: String?
        let gameSlug: String?
        let baseItem: BaseItem?
    }
    private struct BaseItem: Decodable {
        let slug, title: String?
        let keyArt, packArt, primaryLogo: Art?
    }
    private struct Art: Decodable {
        let largestImage: Image?
        struct Image: Decodable { let path: String? }
    }
    private struct LegacyItem: Decodable {
        let productId, groupName, status: String?
    }

    // What the library call leaves behind for the store page: offer id → game slug.
    var slugs = MutexBox<[String: String]>([:])

    func account(_ token: EAToken) async throws -> String {
        let query = "query GetPlayerName { me { player { displayName } } }"
        let body = try await post(query, name: "GetPlayerName", token: token, type: Envelope.self)
        return body?.data?.me?.player?.displayName ?? ""
    }

    // Owned products first (the EA app era), then the legacy entitlements before it.
    func games(_ token: EAToken) async throws -> [StoreGame] {
        var games = try await owned(token)
        var seen = Set(games.map(\.id))
        let found = try await legacy(token)
        games += found.filter { seen.insert($0.id).inserted }
        return games
    }

    func owned(_ token: EAToken) async throws -> [StoreGame] {
        let query = """
        query getPreloadedOwnedGames($limit: Int!, $next: String) {
          me { ownedGameProducts(limit: $limit, next: $next) {
            next items {
              id originOfferId status
              product { name gameSlug baseItem { slug title
                keyArt { largestImage { path } } packArt { largestImage { path } }
                primaryLogo { largestImage { path } } } }
          } } }
        """
        var games: [StoreGame] = []
        var next: String? = nil
        repeat {
            let body = try await post(query, name: "getPreloadedOwnedGames", variables: ["limit": pageSize, "next": next],
                                      token: token, type: Envelope.self)
            let page = body?.data?.me?.ownedGameProducts
            for item in page?.items ?? [] { if let game = Self.game(item) { games.append(game); slugs.value[game.id] = item.product?.gameSlug ?? item.product?.baseItem?.slug } }
            next = page?.next
        } while next != nil
        return games
    }

    private static func game(_ item: Item) -> StoreGame? {
        guard item.status == nil || item.status == "Active",
              let id = item.originOfferId ?? item.id,
              let title = (item.product?.baseItem?.title ?? item.product?.name)?.components(separatedBy: .newlines).joined(separator: " "),
              !title.isEmpty else { return nil }
        return StoreGame(id: id, title: title,
                         art: (item.product?.baseItem?.packArt ?? item.product?.baseItem?.keyArt)
                            .flatMap { $0.largestImage?.path }.flatMap(URL.init(string:)))
    }

    func legacy(_ token: EAToken) async throws -> [StoreGame] {
        let query = """
        query getLegacyEntitlements($limit: Int!, $next: String) {
          me { next items { productId groupName status } }
        }
        """
        var games: [StoreGame] = []
        var next: String? = nil
        repeat {
            let body = try await post(query, name: "getLegacyEntitlements", variables: ["limit": pageSize, "next": next],
                                      token: token, type: Envelope.self)
            for item in body?.data?.me?.items ?? [] {
                guard item.status == nil || item.status == "Active",
                      let id = item.productId else { continue }
                games.append(StoreGame(id: id, title: item.groupName ?? id))
            }
            next = body?.data?.me?.next
        } while next != nil
        return games
    }

    private func post<T: Decodable>(_ query: String, name: String, variables: [String: Any?] = [:],
                                    token: EAToken, type: T.Type) async throws -> T? {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "operationName": name, "query": query,
            "variables": variables.compactMapValues { $0 },
        ])
        let (data, response) = try await http.send(request)
        switch response.statusCode {
        case 200: return try JSONDecoder().decode(T.self, from: data)
        case 400, 401, 403: throw StoreError.sessionExpired
        default: throw StoreError.failed(String(localized: "EA answered \(response.statusCode)."))
        }
    }
}

// A tiny box for the offer id → slug map a library call produces.
final class MutexBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var box: Value
    init(_ value: Value) { box = value }
    var value: Value {
        get { lock.withLock { box } }
        set { lock.withLock { box = newValue } }
    }
}

// Where the EA app's Wine session may have left tokens: bounded folders, *.json files
// only, and only the fields a session needs. A file whose access and refresh are both
// past is not a session and is skipped. File names are not public — this probe is the
// documented, unverified part of the session adoption path.
enum EASessionProbe {
    static let folders = [
        "ProgramData/EA Desktop",
        "ProgramData/Electronic Arts/EA Services",
        "users/crossover/AppData/Local/Electronic Arts/EA Desktop",
    ]

    static func token(in prefix: URL, now: Date) -> EAToken? {
        let fm = FileManager.default
        for relative in folders {
            let dir = prefix.appending(path: "drive_c/\(relative)")
            let files = ((try? fm.contentsOfDirectory(atPath: dir.path(percentEncoded: false))) ?? [])
                .filter { $0.hasSuffix(".json") }.sorted().prefix(32)
            for file in files {
                guard let data = try? Data(contentsOf: dir.appending(path: file)),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let token = read(json, now: now), token.live(at: now) else { continue }
                return token
            }
        }
        return nil
    }

    // After adoption the plain-text session files go: the token lives in the vault only.
    static func scrub(in prefix: URL, now: Date = Date()) {
        let fm = FileManager.default
        for relative in folders {
            let dir = prefix.appending(path: "drive_c/\(relative)")
            let files = ((try? fm.contentsOfDirectory(atPath: dir.path(percentEncoded: false))) ?? [])
                .filter { $0.hasSuffix(".json") }
            for file in files {
                guard let data = try? Data(contentsOf: dir.appending(path: file)),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      read(json, now: now) != nil else { continue }
                try? fm.removeItem(at: dir.appending(path: file))
            }
        }
    }

    private static func read(_ json: [String: Any], now: Date) -> EAToken? {
        let access = (json["access_token"] ?? json["accessToken"]) as? String
        let refresh = (json["refresh_token"] ?? json["refreshToken"]) as? String
        guard let access, !access.isEmpty else { return nil }
        let seconds = { (keys: [String]) -> TimeInterval? in
            for key in keys {
                if let n = (json[key] as? NSNumber)?.doubleValue { return n }
                if let s = (json[key] as? String).flatMap(TimeInterval.init) { return s }
                if let s = json[key] as? String, let date = ISO8601DateFormatter().date(from: s) {
                    return date.timeIntervalSince(now)
                }
            }
            return nil
        }
        return EAToken(accessToken: access, refreshToken: refresh ?? "",
                       expiresAt: now.addingTimeInterval(seconds(["expires_in", "expiresIn"]) ?? 3600),
                       refreshExpiresAt: seconds(["refresh_expires_in", "refreshExpiresIn"]).map { now.addingTimeInterval($0) })
    }
}
