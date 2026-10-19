import Foundation
import Network
import Sparkle
import Testing

@testable import NotProtonApp

@Suite("Update channel", .serialized)
@MainActor
struct UpdateChannelTests {

    @Test("Without the Beta setting only the default channel is allowed")
    func betaOff() {
        #expect(UpdateChannel.allowed(betaOptIn: false).isEmpty)
    }

    @Test("With the Beta setting the beta channel is allowed")
    func betaOn() {
        #expect(UpdateChannel.allowed(betaOptIn: true) == ["beta"])
    }

    @Test("The app's updater reads the setting at each check")
    func delegateReadsTheSetting() {
        let key = UpdateChannel.betaDefaultsKey
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let delegate = UpdateChannelDelegate()
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main,
                                 userDriver: SPUStandardUserDriver(hostBundle: .main, delegate: nil), delegate: nil)
        UserDefaults.standard.removeObject(forKey: key)
        #expect(delegate.allowedChannels(for: updater).isEmpty)
        UserDefaults.standard.set(true, forKey: key)
        #expect(delegate.allowedChannels(for: updater) == ["beta"])
        UserDefaults.standard.set(false, forKey: key)
        #expect(delegate.allowedChannels(for: updater).isEmpty)
    }

    @Test("The daily switch drives Sparkle's automatic check and defaults to on")
    func dailySwitch() {
        let suite = "daily-checks-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(DailyChecks.enabled(defaults))
        defaults.set(false, forKey: DailyChecks.key)
        #expect(!DailyChecks.enabled(defaults))

        var on = true
        let updater = AppUpdater(dailyChecks: { on })
        // Sparkle stores the switch on the host's defaults; leave nothing behind
        defer { UserDefaults.standard.removeObject(forKey: "SUEnableAutomaticChecks") }
        #expect(updater.automaticallyChecks)
        on = false
        updater.applyDailyChecks()
        #expect(!updater.automaticallyChecks)
        on = true
        updater.applyDailyChecks()
        #expect(updater.automaticallyChecks)
    }

    @Test("The Settings toggle and the updater read the same key")
    func toggleSharesTheKey() throws {
        let view = try String(
            contentsOf: IdentityTests.repoRoot.appending(path: "app/Sources/NotProtonApp/Views/UpdatesSettingsView.swift"),
            encoding: .utf8)
        #expect(view.contains("@AppStorage(UpdateChannel.betaDefaultsKey)"))
        #expect(UpdateChannel.betaDefaultsKey == "receiveBetaUpdates")
    }

    // Sparkle itself reads a feed with a release and a newer beta, from a copy at 0.1.0
    @Test("Sparkle offers the beta only to a copy that opted in", arguments: [false, true])
    func sparkleHonorsTheChannel(optedIn: Bool) async throws {
        let found = try await FeedProbe.run(betaOptIn: optedIn)
        #expect(found == (optedIn ? "0.2.0b1" : "0.1.1"))
    }
}

@MainActor
private final class FeedProbe: NSObject, SPUUpdaterDelegate {

    private let channels: UpdateChannelDelegate
    private var continuation: CheckedContinuation<String?, Never>?

    private init(betaOptIn: Bool) {
        channels = UpdateChannelDelegate(betaOptIn: { betaOptIn })
    }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        channels.allowedChannels(for: updater)
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        finish(item.versionString)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        finish(nil)
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        finish("aborted: \(error as NSError)")
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        finish("finished without a result: \(error?.localizedDescription ?? "no error")")
    }

    private func finish(_ version: String?) {
        continuation?.resume(returning: version)
        continuation = nil
    }

    static func run(betaOptIn: Bool) async throws -> String? {
        let dir = FileManager.default.temporaryDirectory.appending(path: "cartouche-feed-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        // Sparkle downloads feeds over http or https only
        let server = try await LoopbackServer.start(body: Data(Self.appcast.utf8))
        defer { server.stop() }
        let feed = server.url.appending(path: "appcast.xml")
        // One fixed ID, so the empty defaults file Sparkle leaves does not pile up
        let bundleID = "dev.bryann2k.cartouche.tests.feedprobe"

        let app = dir.appending(path: "Cartouche.app")
        try FileManager.default.createDirectory(at: app.appending(path: "Contents/MacOS"), withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleName": "Cartouche",
            "CFBundleExecutable": "Cartouche",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "0.1.0",
            "CFBundleVersion": "0.1.0",
            "SUFeedURL": feed.absoluteString,
            "SUPublicEDKey": "GQF06ayCCpIxh8XlQPQYWTwbYO2SckfWqr9rYCuJrqI=",
            "SUEnableAutomaticChecks": false,
            "NSAppTransportSecurity": ["NSAllowsLocalNetworking": true],
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appending(path: "Contents/Info.plist"))
        let host = try #require(Bundle(url: app))

        let probe = FeedProbe(betaOptIn: betaOptIn)
        let driver = SPUStandardUserDriver(hostBundle: host, delegate: nil)
        let updater = SPUUpdater(hostBundle: host, applicationBundle: host, userDriver: driver, delegate: probe)
        try updater.start()

        let timeout = Task { @MainActor in
            try await Task.sleep(for: .seconds(30))
            probe.finish("timed out")
        }
        let found = await withCheckedContinuation { continuation in
            probe.continuation = continuation
            updater.checkForUpdateInformation()
        }
        timeout.cancel()

        // Sparkle records the check in the fake app's defaults once the cycle ends
        try? await Task.sleep(for: .milliseconds(500))
        UserDefaults.standard.removePersistentDomain(forName: bundleID)
        return found
    }

    private static let appcast = """
        <?xml version="1.0" encoding="utf-8"?>
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
          <channel>
            <title>Cartouche</title>
            <item>
              <title>0.2.0-beta.1</title>
              <sparkle:channel>beta</sparkle:channel>
              <sparkle:version>0.2.0b1</sparkle:version>
              <sparkle:shortVersionString>0.2.0-beta.1</sparkle:shortVersionString>
              <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
              <enclosure url="https://example.test/v0.2.0-beta.1/Cartouche-0.2.0-beta.1.zip" length="1"
                type="application/octet-stream" sparkle:edSignature="AAAA"/>
            </item>
            <item>
              <title>0.1.1</title>
              <sparkle:version>0.1.1</sparkle:version>
              <sparkle:shortVersionString>0.1.1</sparkle:shortVersionString>
              <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
              <enclosure url="https://example.test/v0.1.1/Cartouche-0.1.1.zip" length="1"
                type="application/octet-stream" sparkle:edSignature="AAAA"/>
            </item>
          </channel>
        </rss>
        """
}

// Answers every request on 127.0.0.1 with one body
private final class LoopbackServer: Sendable {

    let url: URL
    private let listener: NWListener

    private init(listener: NWListener, port: UInt16) {
        self.listener = listener
        url = URL(string: "http://127.0.0.1:\(port)")!
    }

    static func start(body: Data) async throws -> LoopbackServer {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: params)
        let queue = DispatchQueue(label: "cartouche.tests.loopback")
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { _, _, _, _ in
                let head = "HTTP/1.1 200 OK\r\nContent-Type: application/xml\r\nContent-Length: \(body.count)\r\n"
                    + "Connection: close\r\n\r\n"
                connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        return LoopbackServer(listener: listener, port: port)
    }

    func stop() {
        listener.cancel()
    }
}
