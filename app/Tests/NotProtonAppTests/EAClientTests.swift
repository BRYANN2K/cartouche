import Foundation
import Testing

@testable import NotProtonApp

// EA's adopted launcher session and the private owned-games API. The responses are
// hand-written fixtures in the shapes the EA app exchanges — no real account, and the
// token only ever lives in the vault.
@Suite("EA client", .serialized)
struct EAClientTests {

    @Test("token.json round-trips; access expiry is separate from refresh expiry")
    func token() throws {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        var token = EAToken(accessToken: "ea-access", refreshToken: "ea-refresh",
                            expiresAt: at.addingTimeInterval(3599), refreshExpiresAt: at.addingTimeInterval(360_000))
        let back = try #require(EAToken.read(try token.json()))
        #expect(abs(back.expiresAt.timeIntervalSince(token.expiresAt)) < 1)
        #expect(back.accessToken == "ea-access" && back.refreshExpiresAt != nil)
        #expect(token.expired(at: at.addingTimeInterval(3600)) && !token.expired(at: at.addingTimeInterval(3598)))
        token.refreshExpiresAt = nil
        #expect(EAToken.read(try token.json())?.refreshExpiresAt == nil)
        #expect(EAToken.read(Data("not json".utf8)) == nil)
        // Live while either the access token or the refresh window still stands
        #expect(token.live(at: at))
        let dead = EAToken(accessToken: "a", refreshToken: "r",
                           expiresAt: at.addingTimeInterval(-1), refreshExpiresAt: at.addingTimeInterval(-1))
        #expect(!dead.live(at: at))
        #expect(dead.live(at: at.addingTimeInterval(-2)))
    }

    static func session(_ token: String = "ea-access") -> String {
        #"{"access_token": "\#(token)", "refresh_token": "ea-refresh", "expires_in": 3599, "refresh_expires_in": 360000, "token_type": "Bearer"}"#
    }

    @Test("refresh() POSTs the refresh grant; a 401 is an expired session")
    func grants() async throws {
        let server = try StoreAPIServer()
        let base = try await server.start()
        defer { server.stop() }
        server.put("/connect/token", json: Self.session())
        var flow = EAAuthFlow()
        flow.tokenURL = base.appending(path: "connect/token")
        let stale = EAToken(accessToken: "ea-stale", refreshToken: "ea-refresh",
                            expiresAt: flow.now().addingTimeInterval(-60), refreshExpiresAt: flow.now().addingTimeInterval(360_000))
        let refreshed = try await flow.refresh(stale)
        // grant fields went form-encoded to the token endpoint
        let posted = try #require(server.requests.last?.body.map { String(decoding: $0, as: UTF8.self) })
        #expect(posted.contains("grant_type=refresh_token") && posted.contains("refresh_token=ea-refresh")
            && posted.contains("client_id=JUNO_PC_CLIENT"))
        #expect(refreshed.accessToken == "ea-access" && refreshed.refreshToken == "ea-refresh")
        server.fail("/connect/token", with: 401)
        await #expect(throws: StoreError.sessionExpired) { _ = try await flow.refresh(stale) }
    }

    // data.me.ownedGameProducts for getPreloadedOwnedGames — two pages of fixtures
    static let ownedPage1 = #"""
    {"data": {"me": {"ownedGameProducts": {"next": "cursor-2", "totalCount": 3, "items": [
      {"id": "prod-1", "originOfferId": "Origin.OFR.50.00040000", "status": "Active",
       "product": {"id": "prod-1", "name": "Sample EA Game", "downloadable": true, "gameSlug": "sample-ea-game",
         "baseItem": {"id": "base-1", "slug": "sample-ea-game", "title": "Sample EA Game",
           "keyArt": {"largestImage": {"path": "https://cdn.ea.com/key.jpg"}},
           "packArt": {"largestImage": {"path": "https://cdn.ea.com/pack.jpg"}},
           "primaryLogo": {"largestImage": {"path": "https://cdn.ea.com/logo.jpg"}}},
         "gameProductUser": {"status": "Active"}}},
      {"id": "prod-2", "originOfferId": "Origin.OFR.50.00040001", "status": "Inactive",
       "product": {"id": "prod-2", "name": "Revoked Game", "downloadable": true, "gameSlug": "revoked"}}]}}}}
    """#
    static let ownedPage2 = #"""
    {"data": {"me": {"ownedGameProducts": {"next": null, "totalCount": 3, "items": [
      {"id": "prod-3", "originOfferId": "Origin.OFR.50.00040002", "status": "Active",
       "product": {"id": "prod-3", "name": "Second\nEA Game", "downloadable": true, "gameSlug": "second-ea-game",
         "baseItem": {"id": "base-3", "slug": "second-ea-game", "title": "Second EA Game"}}}]}}}}
    """#
    // data.me is itself the page for getLegacyEntitlements
    static let legacy = #"""
    {"data": {"me": {"next": null, "items": [
      {"id": "ent-1", "productId": "OFR.legacy-1", "entitlementTag": "SW_SIMCITY", "entitlementType": "OnlineAccess",
       "groupName": "Sample Legacy Game", "status": "Active", "grantDate": "2026-01-01T00:00:00Z", "useCount": 1, "version": 0},
      {"id": "ent-2", "productId": "OFR.legacy-2", "groupName": "Expired Legacy", "status": "Expired", "useCount": 0, "version": 0}]}}}
    """#
    static let whoami = #"{"data": {"me": {"player": {"displayName": "Player One"}}}}"#

    @Test("library(): every page of owned products, then the legacy entitlements it predates")
    func library() async throws {
        let server = try StoreAPIServer()
        let base = try await server.start()
        defer { server.stop() }
        var api = EALibrary()
        api.endpoint = base.appending(path: "graphql")
        api.pageSize = 2
        let page = MutexBox(0)
        server.post("/graphql") { request in
            defer { page.value += 1 }
            let body = String(decoding: request.body ?? Data(), as: UTF8.self)
            if body.contains("getLegacyEntitlements") { return (200, Data(Self.legacy.utf8)) }
            if body.contains("GetPlayerName") { return (200, Data(Self.whoami.utf8)) }
            return (200, Data((page.value == 0 ? Self.ownedPage1 : Self.ownedPage2).utf8))
        }
        let token = EAToken(accessToken: "ea-access", refreshToken: "r", expiresAt: Date().addingTimeInterval(3600))
        let games = try await api.games(token)
        #expect(games.map(\.id) == ["Origin.OFR.50.00040000", "Origin.OFR.50.00040002", "OFR.legacy-1"])
        #expect(games[0].title == "Sample EA Game")
        #expect(games[0].art == URL(string: "https://cdn.ea.com/pack.jpg"))
        #expect(games[1].title == "Second EA Game") // newlines dropped
        // Two owned pages, the legacy page, each with the bearer token
        let calls = server.requests.filter { $0.path == "/graphql" }
        #expect(calls.count == 3)
        #expect(calls.allSatisfy { $0.authorization == "Bearer ea-access" })
        // The account name comes from the same bearer
        #expect(try await api.account(token) == "Player One")
        server.fail("/graphql", with: 401)
        await #expect(throws: StoreError.sessionExpired) { _ = try await api.games(token) }
    }

    @Test("the session probe reads a launcher-written JSON, in bounded folders only, and skips dead sessions")
    func probe() throws {
        let root = try scratchDirectory("ea-probe")
        defer { try? FileManager.default.removeItem(at: root) }
        let prefix = root.appending(path: "pfx")
        let sessions = prefix.appending(path: "drive_c/ProgramData/EA Desktop")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        // A fixture of the shape the launcher's session files show: bearer + refresh + expiry
        try Data(#"{"access_token": "ea-session", "refresh_token": "ea-session-refresh", "expires_in": 3599}"#.utf8)
            .write(to: sessions.appending(path: "session.json"))
        try Data(#"{"not_a": "session"}"#.utf8).write(to: sessions.appending(path: "settings.json"))
        let token = try #require(EASessionProbe.token(in: prefix, now: Date()))
        #expect(token.accessToken == "ea-session" && token.refreshToken == "ea-session-refresh")
        // A dead session file (access and refresh both past) is not adoptable — the probe skips it
        try Data(#"{"access_token": "a-dead", "refresh_token": "a-dead-refresh", "expires_in": -10, "refresh_expires_in": -10}"#.utf8)
            .write(to: sessions.appending(path: "a-dead.json"))
        #expect(EASessionProbe.token(in: prefix, now: Date())?.accessToken == "ea-session")
        // Files elsewhere in the prefix are not read
        let elsewhere = root.appending(path: "pfx2")
        try FileManager.default.createDirectory(at: elsewhere.appending(path: "drive_c/users/crossover"),
                                                withIntermediateDirectories: true)
        try Data(#"{"access_token": "sneaky", "refresh_token": "sneaky"}"#.utf8)
            .write(to: elsewhere.appending(path: "drive_c/users/crossover/secret.json"))
        #expect(EASessionProbe.token(in: elsewhere, now: Date()) == nil)
    }
}
