import Foundation
import Testing

@testable import NotProtonApp

// Every request URLSession.shared starts while it is installed, with its body. Only the
// test address is answered; anything else is recorded and passed on.
final class RequestCapture: URLProtocol, @unchecked Sendable {
    struct Seen: Sendable {
        let url: URL?
        let body: Data?
    }

    nonisolated(unsafe) private static var seen: [Seen] = []
    private static let lock = NSLock()
    static let host = "reports.cartouche.test"

    static func start() {
        lock.withLock { seen = [] }
        URLProtocol.registerClass(RequestCapture.self)
    }

    static func stop() -> [Seen] {
        URLProtocol.unregisterClass(RequestCapture.self)
        return lock.withLock { seen }
    }

    static func body(_ request: URLRequest) -> Data? {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }

    override class func canInit(with request: URLRequest) -> Bool {
        lock.withLock { seen.append(Seen(url: request.url, body: body(request))) }
        return request.url?.host == host
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("Sharing frame rates", .serialized)
@MainActor
struct PerformanceSharingTests {

    nonisolated static let testEndpoint: @Sendable (Int) -> URL = { URL(string: "https://\(RequestCapture.host)/games/\($0)/reports")! }
    nonisolated static let mac = PerformanceReport.Mac(chip: "M4 Pro", memoryGB: 24, macOS: "26.1.0")

    // A session as the run script records it, with settings that name a path and the account
    func endedSession(_ fixture: PerformanceFixture) throws {
        let start = PerformanceFixture.start
        try fixture.launch("1245620-a-1", display: "CrossOver 26.3 · DXMT", ended: start + 400, seconds: 330, fps: 58,
                           settings: ["MTL_HUD_ENABLED=1", "DXVK_LOG_PATH=/Users/player42/logs", "DXMT_LOG_LEVEL=info",
                                      "D3DM_ENABLE_METALFX=1", "DXVK_CONFIG=dxgi.customVendorId=76561198000000042/x"])
    }

    func model(_ fixture: PerformanceFixture, _ scratch: ScratchDefaults, endpoint: (@Sendable (Int) -> URL)?) -> PerformanceModel {
        PerformanceModel(store: fixture.store,
                         sharing: PerformanceSharing(endpoint: endpoint, mac: { Self.mac }),
                         defaults: scratch.defaults)
    }

    static func carriesPlayData(_ seen: RequestCapture.Seen) -> Bool {
        let text = seen.body.map { String(decoding: $0, as: UTF8.self) } ?? ""
        return seen.url?.host == RequestCapture.host || text.contains("fps") || text.contains("measured_seconds")
    }

    @Test("Off by default: with default settings, no request during or after a session carries play data")
    func offByDefault() async throws {
        let fixture = try PerformanceFixture("share-off")
        defer { fixture.remove() }
        let scratch = ScratchDefaults()
        #expect(PrivacyChoices(defaults: scratch.defaults).sharePerformance == false)
        // Even with an address to send to, the default setting sends nothing
        let model = model(fixture, scratch, endpoint: Self.testEndpoint)
        RequestCapture.start()
        let folder = fixture.store.incoming.appending(path: "1245620-a-1")
        try fixture.launch("1245620-a-1", seconds: 120)
        await model.refresh()  // during: the game still runs
        try FileHandle(forWritingTo: folder.appending(path: "session")).seekAndAppend("ended=\(PerformanceFixture.start + 200)\n")
        await model.refresh()  // after: the session is read in
        let seen = RequestCapture.stop()
        #expect(model.play(appID: 1_245_620) != nil)
        let urls = seen.compactMap { $0.url?.absoluteString }
        #expect(!seen.contains(where: Self.carriesPlayData), "requests: \(urls)")
    }

    @Test("This build has no MacGamingDB address, so sharing is unavailable and sends nothing even when on")
    func unavailable() async throws {
        let fixture = try PerformanceFixture("share-none")
        defer { fixture.remove() }
        let scratch = ScratchDefaults()
        let choices = PrivacyChoices(defaults: scratch.defaults)
        choices.sharePerformance = true
        #expect(!PerformanceSharing().isAvailable)
        try endedSession(fixture)
        let model = PerformanceModel(store: fixture.store, sharing: PerformanceSharing(mac: { Self.mac }), defaults: scratch.defaults)
        RequestCapture.start()
        await model.refresh()
        let seen = RequestCapture.stop()
        #expect(!seen.contains(where: Self.carriesPlayData))
        #expect(PerformanceSharing().request(for: try #require(try fixture.store.sessions().first)) == nil)
    }

    @Test("What is shared: chip, RAM, macOS version, runner, backend, settings and FPS, and no account name, path or Steam ID")
    func whatIsShared() async throws {
        let fixture = try PerformanceFixture("share-on")
        defer { fixture.remove() }
        let scratch = ScratchDefaults()
        PrivacyChoices(defaults: scratch.defaults).sharePerformance = true
        try endedSession(fixture)
        let model = model(fixture, scratch, endpoint: Self.testEndpoint)
        RequestCapture.start()
        await model.refresh()
        let seen = RequestCapture.stop().filter { $0.url?.host == RequestCapture.host }
        #expect(seen.count == 1)
        let sent = try #require(seen.first)
        #expect(sent.url?.absoluteString == "https://reports.cartouche.test/games/1245620/reports")
        let body = try #require(sent.body)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(Set(json.keys) == ["mac", "runner", "runner_build", "translation", "backend", "settings", "fps"])
        let mac = try #require(json["mac"] as? [String: Any])
        #expect(mac["chip"] as? String == "M4 Pro")
        #expect(mac["ram_gb"] as? Int == 24)
        #expect(mac["macos"] as? String == "26.1.0")
        #expect(json["runner"] as? String == "CrossOver 26.3")
        #expect(json["runner_build"] as? String == "26.3.0.39832")
        #expect(json["translation"] as? String == "rosetta")
        #expect(json["backend"] as? String == "dxmt")
        #expect(json["settings"] as? [String: String] == ["MTL_HUD_ENABLED": "1", "D3DM_ENABLE_METALFX": "1", "resolution": "2560x1440"])
        let fps = try #require(json["fps"] as? [String: Any])
        #expect(fps["average"] as? Double == 58)
        #expect(fps["low_1_percent"] as? Double == 58)
        #expect(fps["measured_seconds"] as? Int == 300)
        let text = String(decoding: body, as: UTF8.self)
        for forbidden in ["player42", "/Users", "/", SteamFixture.steamID, NSUserName(), NSHomeDirectory()] {
            #expect(!text.contains(forbidden), "the body carries \(forbidden)")
        }
        // Sent once: a second refresh has no new session
        RequestCapture.start()
        await model.refresh()
        let again = RequestCapture.stop().filter { $0.url?.host == RequestCapture.host }
        #expect(again.isEmpty)
    }

    @Test("Only measured sessions are reported, and sharing off sends none")
    func onlyMeasured() async throws {
        let refused = PlayStatsTests.session(1, setup: PlayStatsTests.dxvk, hours: 1, fps: 0, measurement: .refused)
        let measured = PlayStatsTests.session(2, setup: PlayStatsTests.dxmt, hours: 1, fps: 60)
        let sharing = PerformanceSharing(endpoint: Self.testEndpoint, mac: { Self.mac })
        #expect(sharing.request(for: refused) == nil)
        #expect(sharing.request(for: measured)?.httpMethod == "POST")
        RequestCapture.start()
        #expect(await sharing.share([refused, measured], enabled: false) == 0)
        #expect(await sharing.share([refused, measured], enabled: true) == 1)
        let reports = RequestCapture.stop().filter { $0.url?.host == RequestCapture.host }
        #expect(reports.count == 1)
    }
}

private extension FileHandle {
    func seekAndAppend(_ text: String) throws {
        try seekToEnd()
        try write(contentsOf: Data(text.utf8))
        try close()
    }
}
