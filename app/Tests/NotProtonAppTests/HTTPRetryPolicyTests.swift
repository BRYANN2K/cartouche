import CartoucheMCP
import Foundation
import Testing

@testable import NotProtonApp

@Suite("HTTP retry policy")
struct HTTPRetryPolicyTests {

    private static let now = Date(timeIntervalSince1970: 1_784_000_000)
    private static let url = URL(string: "https://macgamingdb.app/api/rest/games/1")!

    @Test("Retry-After reads delay-seconds and the three HTTP-date forms")
    func parsesRetryAfter() {
        #expect(RetryAfter.seconds("120", now: Self.now) == 120)
        #expect(RetryAfter.seconds(" 0 ", now: Self.now) == 0)
        #expect(RetryAfter.seconds("99999999999999999999999", now: Self.now) == RetryAfter.longest)
        let later = Self.now.addingTimeInterval(90)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        for format in ["EEE, dd MMM yyyy HH:mm:ss 'GMT'", "EEEE, dd-MMM-yy HH:mm:ss 'GMT'", "EEE MMM d HH:mm:ss yyyy"] {
            formatter.dateFormat = format
            #expect(RetryAfter.seconds(formatter.string(from: later), now: Self.now) == 90)
        }
        #expect(RetryAfter.seconds("Mon, 01 Jan 2001 00:00:00 GMT", now: Self.now) == 0)
        #expect(RetryAfter.seconds(nil) == nil)
        #expect(RetryAfter.seconds("-5") == nil)
        #expect(RetryAfter.seconds("soon") == nil)
    }

    @Test("Backoff doubles from the base, stays under the cap, and yields to a longer Retry-After")
    func backsOff() {
        let backoff = HTTPBackoff(base: 10, cap: 100)
        #expect(backoff.delay(attempt: 1, jitter: 0) == 5)
        #expect(backoff.delay(attempt: 1, jitter: 1) == 10)
        #expect(backoff.delay(attempt: 3, jitter: 1) == 40)
        #expect(backoff.delay(attempt: 50, jitter: 1) == 100)
        #expect(backoff.delay(attempt: 2, retryAfter: 600, jitter: 1) == 600)
        for _ in 0..<50 { #expect((50...100).contains(backoff.delay(attempt: 9))) }
        #expect(HTTPBackoff.throttles(429) && HTTPBackoff.throttles(503) && !HTTPBackoff.throttles(500))
    }

    @Test("A throttled host is paused until its delay ends, and a good answer clears it")
    func cooldownPauses() async {
        let cooldown = HTTPCooldown(backoff: HTTPBackoff(base: 10, cap: 100))
        #expect(await cooldown.note(Self.url, status: 429, retryAfter: "60", now: Self.now, jitter: 0) == 60)
        #expect(await cooldown.isPaused(Self.url, now: Self.now.addingTimeInterval(59)))
        #expect(await !cooldown.isPaused(URL(string: "https://store.steampowered.com/api")!, now: Self.now))
        #expect(await !cooldown.isPaused(Self.url, now: Self.now.addingTimeInterval(60)))
        #expect(await cooldown.note(Self.url, status: 503, retryAfter: nil, now: Self.now, jitter: 1) == 20)
        #expect(await cooldown.note(Self.url, status: 200, retryAfter: nil, now: Self.now) == nil)
        #expect(await !cooldown.isPaused(Self.url, now: Self.now))
    }

    @Test("A 429 stops the next request from going out")
    func throttledFetchStops() async throws {
        final class Count: @unchecked Sendable {
            let lock = NSLock()
            var value = 0
            func bump() { lock.withLock { value += 1 } }
        }
        let sent = Count()
        let fetch = HTTPFetch.throttled(HTTPCooldown()) { _ in
            sent.bump()
            return (Data(), 429, "3600")
        }
        #expect(try await fetch(Self.url).1 == 429)
        #expect(try await fetch(Self.url).1 == 429)
        #expect(sent.value == 1)
    }

    @Test("The MCP bearer token is 32 random bytes in hex")
    func mcpToken() {
        let token = MCPToken.generate()
        #expect(token.hasPrefix("cartouche-"))
        #expect(token.count == "cartouche-".count + 64)
        #expect(token != MCPToken.generate())
    }
}
