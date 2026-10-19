import Foundation
import Testing

@testable import NotProtonApp

@Suite("MacGamingDB read live")
struct MacGamingDBTests {

    // Answers from a script, counting requests and how many run at once
    private final class Server: @unchecked Sendable {
        private let lock = NSLock()
        private var answer: @Sendable (URL) throws -> (Data, Int)
        private(set) var asked: [URL] = []
        private(set) var busiest = 0
        private var running = 0
        let delay: UInt64

        init(delay: UInt64 = 0, _ answer: @escaping @Sendable (URL) throws -> (Data, Int)) {
            self.answer = answer
            self.delay = delay
        }

        func set(_ answer: @escaping @Sendable (URL) throws -> (Data, Int)) {
            lock.lock(); self.answer = answer; lock.unlock()
        }

        private func begin(_ url: URL) -> @Sendable (URL) throws -> (Data, Int) {
            lock.lock(); defer { lock.unlock() }
            asked.append(url)
            running += 1
            busiest = max(busiest, running)
            return answer
        }

        private func end() {
            lock.lock(); running -= 1; lock.unlock()
        }

        func fetch(_ url: URL) async throws -> (Data, Int) {
            let answer = begin(url)
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            end()
            return try answer(url)
        }
    }

    private static func eldenRing() throws -> Data { try Data(contentsOf: CompatFixture.eldenRingAnswer) }
    private static let day = CompatFixture.generated

    private func client(_ work: URL, _ server: Server) -> MacGamingDBClient {
        MacGamingDBClient(directory: work.appending(path: "macgamingdb")) { try await server.fetch($0) }
    }

    @Test("The recorded Elden Ring answer reads as Very Good with D3DMetal most reported")
    func parsesTheAnswer() throws {
        let entry = try CompatFixture.eldenRingMac()
        #expect(entry.rating == .veryGood)
        #expect(entry.topLayer == .d3dmetal)
        #expect(entry.reviewCount == 26)
        #expect(entry.reports.count == 25)
        #expect(entry.reports.filter { $0.layer == .d3dmetal }.count == 21)
        #expect(entry.reports.first == MacReport(chip: "M4", method: .wine, layer: nil, rating: 5, fps: nil, settings: .medium, date: "2025-04-20"))
    }

    @Test("First open asks once and caches; a second open the same day asks nothing")
    @MainActor
    func firstAndSecondOpen() async throws {
        let work = try scratchDirectory("mgdb-open")
        defer { try? FileManager.default.removeItem(at: work) }
        let body = try Self.eldenRing()
        let server = Server { _ in (body, 200) }
        let scratch = ScratchDefaults()
        let model = CompatibilityModel(client: CompatibilityClient(directory: work), macGamingDB: client(work, server),
                                       choices: PrivacyChoices(defaults: scratch.defaults))
        model.now = { Self.day }

        await model.openGame(appID: 1245620)
        #expect(server.asked.map(\.absoluteString) == ["https://macgamingdb.app/api/rest/games/1245620"])
        #expect(FileManager.default.fileExists(atPath: work.appending(path: "macgamingdb/1245620.json").path))
        let panel = model.panel(appID: 1245620, method: .wine)
        #expect(panel.mac?.rating?.label == "Very Good")
        #expect(panel.mac?.topLayer == .d3dmetal)

        model.now = { Self.day.addingTimeInterval(20 * 3600) }
        await model.openGame(appID: 1245620)
        #expect(server.asked.count == 1)

        // A new app session reads the same cache
        let again = CompatibilityModel(client: CompatibilityClient(directory: work), macGamingDB: client(work, server),
                                       choices: PrivacyChoices(defaults: scratch.defaults))
        again.now = { Self.day.addingTimeInterval(23 * 3600) }
        await again.openGame(appID: 1245620)
        #expect(server.asked.count == 1)
        #expect(again.panel(appID: 1245620, method: .wine).mac?.rating == .veryGood)
    }

    @Test("After a day the game is asked again; offline, the last good copy stays")
    func refreshAndOffline() async throws {
        let work = try scratchDirectory("mgdb-offline")
        defer { try? FileManager.default.removeItem(at: work) }
        let body = try Self.eldenRing()
        let server = Server { _ in (body, 200) }
        let mgdb = client(work, server)
        #expect(await mgdb.reports(appID: 1245620, now: Self.day)?.rating == .veryGood)

        server.set { _ in throw URLError(.notConnectedToInternet) }
        let later = Self.day.addingTimeInterval(25 * 3600)
        #expect(await mgdb.reports(appID: 1245620, now: later)?.rating == .veryGood)
        #expect(server.asked.count == 2)

        server.set { _ in (Data("<html>busy</html>".utf8), 200) }
        #expect(await mgdb.reports(appID: 1245620, now: later)?.topLayer == .d3dmetal)
        server.set { _ in (Data(), 503) }
        #expect(await mgdb.reports(appID: 1245620, now: later)?.reports.count == 25)
        #expect(server.asked.count == 4)
    }

    @Test("Offline with nothing cached gives no reports; a game MacGamingDB does not know is cached as empty")
    func nothingCached() async throws {
        let work = try scratchDirectory("mgdb-none")
        defer { try? FileManager.default.removeItem(at: work) }
        let server = Server { _ in throw URLError(.notConnectedToInternet) }
        let mgdb = client(work, server)
        #expect(await mgdb.reports(appID: 1245620, now: Self.day) == nil)

        server.set { _ in (Data(#"{"message":"not found"}"#.utf8), 404) }
        #expect(await mgdb.reports(appID: 42, now: Self.day) == .empty)
        #expect(await mgdb.reports(appID: 42, now: Self.day.addingTimeInterval(60)) == .empty)
        #expect(server.asked.count == 2)
    }

    @Test("At most two requests run at once, and one game is asked once even when opened twice")
    func politeness() async throws {
        let work = try scratchDirectory("mgdb-polite")
        defer { try? FileManager.default.removeItem(at: work) }
        let body = try Self.eldenRing()
        let server = Server(delay: 50_000_000) { _ in (body, 200) }
        let mgdb = client(work, server)
        await withTaskGroup(of: Void.self) { group in
            for app in [1, 2, 3, 4, 5, 5, 5] {
                group.addTask { _ = await mgdb.reports(appID: app, now: Self.day) }
            }
        }
        #expect(server.busiest <= MacGamingDBClient.maxConcurrent)
        #expect(server.asked.count == 5)
    }

    @Test("With Mac reports off, nothing goes to MacGamingDB and the estimate says reports are off")
    @MainActor
    func toggleOff() async throws {
        let work = try scratchDirectory("mgdb-off")
        defer { try? FileManager.default.removeItem(at: work) }
        let body = try Self.eldenRing()
        let server = Server { _ in (body, 200) }
        let scratch = ScratchDefaults()
        let choices = PrivacyChoices(defaults: scratch.defaults)
        #expect(choices.fetchMacReports, "on by default")
        choices.fetchMacReports = false
        #expect(PrivacyChoices(defaults: scratch.defaults).fetchMacReports == false, "the choice is kept")

        let model = CompatibilityModel(client: CompatibilityClient(directory: work), macGamingDB: client(work, server), choices: choices)
        await model.load()
        await model.openGame(appID: 1245620)
        #expect(server.asked.isEmpty)
        let panel = model.panel(appID: 1245620, method: .wine)
        let (_, line) = GamePanelContent.estimate(panel.estimate, macReportsOn: panel.macReportsOn)
        #expect(line == "Mac reports are turned off in Settings > Privacy")
        #expect(panel.mac == nil)
    }

    @Test("With Mac reports off, a game already cached still shows no MacGamingDB data, and the wiki stays")
    @MainActor
    func toggleOffHidesCache() async throws {
        let data = try CompatFixture.data()
        let panel = CompatibilityPanel(record: data.record(appID: 1245620), mac: try CompatFixture.eldenRingMac(),
                                       macReportsOn: false, method: .wine, chip: "M4", data: data, ageNotice: nil)
        #expect(panel.mac == nil)
        #expect(panel.estimate == .noReports)
        #expect(panel.wiki?.ratings["crossover"] == "playable")
    }

    @Test("Unknown values leave a report out instead of guessing")
    func unknownValues() throws {
        let base: [String: Any] = ["chipset": "M4", "chipsetVariant": "PRO", "playMethod": "CROSSOVER",
                                   "translationLayer": "D3D_METAL", "performance": "GOOD", "fps": 45,
                                   "graphicsSettings": "HIGH", "createdAt": "2025-04-20T20:10:27.935+00:00"]
        func parse(_ change: [String: Any]) throws -> [MacReport] {
            let review = base.merging(change) { $1 }
            let answer: [String: Any] = ["game": ["aggregatedPerformance": "GOOD"], "reviews": [review]]
            return try MacGamingDBEntry.parse(JSONSerialization.data(withJSONObject: answer)).reports
        }
        #expect(try parse([:]) == [MacReport(chip: "M4 Pro", method: .wine, layer: .d3dmetal, rating: 3, fps: 45, settings: .high, date: "2025-04-20")])
        for change: [String: Any] in [["chipset": "INTEL"], ["chipsetVariant": "MEGA"], ["playMethod": "BOOTCAMP"],
                                      ["performance": "SUPERB"], ["translationLayer": "VKD3D"], ["graphicsSettings": "EPIC"]] {
            #expect(try parse(change).isEmpty, "\(change)")
        }
        #expect(try parse(["fps": 0]).first?.fps == nil)
        #expect(try parse(["fps": 5000]).first?.fps == nil)
        #expect(throws: MacGamingDBEntry.Unreadable.self) { try MacGamingDBEntry.parse(Data("{}".utf8)) }
    }

    @Test("The requests name Cartouche and its site")
    func userAgent() {
        let agent = MacGamingDBClient.userAgent
        #expect(agent.hasPrefix("Cartouche/"))
        #expect(agent.hasSuffix("(+https://cartouche.bryann2k.dev)"))
    }
}
