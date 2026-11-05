import Foundation
import Synchronization
import Testing

@testable import NotProtonApp

// The vendors replace their installers in place, so nothing here is pinned: HTTPS, the
// vendor's own hosts at every hop and a size that fits are what stand in for a hash.
final class InstallerStub: URLProtocol {
    struct Route {
        var status = 200
        var body = Data()
        var redirect: URL? = nil
    }

    private static let table = Mutex<[String: Route]>([:])

    static func serve(_ routes: [String: Route]) { table.withLock { $0 = routes } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let client, let url = request.url else { return }
        guard let route = Self.table.withLock({ $0[url.absoluteString] }) else {
            client.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        if let target = route.redirect {
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil,
                                           headerFields: ["Location": target.absoluteString])!
            client.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            client.urlProtocolDidFinishLoading(self)
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: route.status, httpVersion: nil,
                                       headerFields: ["Content-Length": String(route.body.count)])!
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client.urlProtocol(self, didLoad: route.body)
        client.urlProtocolDidFinishLoading(self)
    }
}

@Suite("Launcher installer download", .serialized)
struct LauncherInstallerTests {
    private final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func add(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
    }

    private let entry = URL(string: "https://static3.cdn.ubi.com/orbit/Setup.exe")!
    private let mirror = URL(string: "https://ubistatic3-a.akamaihd.net/orbit/Setup.exe")!
    private let elsewhere = URL(string: "https://static3.cdn.ubi.com.evil.example/Setup.exe")!
    private let session = PinnedDownload.session(deadline: 30, protocols: [InstallerStub.self])

    private var installer: LauncherInstaller {
        LauncherInstaller(store: .ubisoft, url: entry, hosts: ["static3.cdn.ubi.com", "ubistatic3-a.akamaihd.net"], sizes: 10...100)
    }

    private func download(_ installer: LauncherInstaller, log: Log = Log(), progress: Log = Log()) async throws -> (URL, URL) {
        let work = try scratchDirectory("installer")
        let file = try await installer.download(into: work, session: session, fraction: { progress.add(String($0)) }, log: log.add)
        return (file, work)
    }

    private func refused(_ installer: LauncherInstaller, saying word: String) async throws {
        let work = try scratchDirectory("installer-refused")
        defer { try? FileManager.default.removeItem(at: work) }
        do {
            _ = try await installer.download(into: work, session: session, fraction: { _ in }, log: { _ in })
            Issue.record("the download went through")
        } catch {
            #expect(error.localizedDescription.contains(word), "\(error.localizedDescription)")
        }
        let left = (try? FileManager.default.contentsOfDirectory(atPath: work.path(percentEncoded: false))) ?? []
        #expect(left.isEmpty, "\(left)")
    }

    @Test("Both vendors' installers are HTTPS on their own hosts, each with its own size bound")
    func official() throws {
        for (store, host, size) in [(GameSource.ubisoft, "static3.cdn.ubi.com", Int64(262_918_936)),
                                    (.ea, "origin-a.akamaihd.net", 2_141_200)] {
            let installer = try #require(LauncherInstaller.official(store))
            #expect(installer.allows(installer.url))
            #expect(installer.url.host() == host)
            #expect(installer.sizes.contains(size))
            #expect(!installer.sizes.contains(1024))
            #expect(!installer.sizes.contains(2_000_000_000))
        }
        #expect(LauncherInstaller.official(.gog) == nil)
    }

    @Test("Only https on an exact listed host passes", arguments: [
        ("https://static3.cdn.ubi.com/a.exe", true),
        ("https://STATIC3.cdn.ubi.com/a.exe", true),
        ("http://static3.cdn.ubi.com/a.exe", false),
        ("https://static3.cdn.ubi.com.evil.example/a.exe", false),
        ("https://evil.example/static3.cdn.ubi.com/a.exe", false),
        ("https://sub.static3.cdn.ubi.com/a.exe", false),
    ])
    func hosts(url: String, allowed: Bool) {
        #expect(installer.allows(URL(string: url)) == allowed)
    }

    @Test("A good download lands, and the log gets its host, size and SHA-256")
    func good() async throws {
        let body = Data(repeating: 7, count: 50)
        InstallerStub.serve([entry.absoluteString: .init(body: body)])
        let log = Log(), progress = Log()
        let (file, work) = try await download(installer, log: log, progress: progress)
        defer { try? FileManager.default.removeItem(at: work) }
        #expect(try Data(contentsOf: file) == body)
        #expect(file.lastPathComponent == "Setup.exe")
        let line = try #require(log.all.first)
        #expect(line.contains(Digest.sha256(of: body)))
        #expect(line.contains("static3.cdn.ubi.com"))
        #expect(line.contains("50"))
        #expect(progress.all.last == "1.0")
    }

    @Test("A redirect stays allowed while it stays on the vendor's hosts")
    func redirectOnList() async throws {
        InstallerStub.serve([entry.absoluteString: .init(redirect: mirror),
                             mirror.absoluteString: .init(body: Data(repeating: 1, count: 40))])
        let (file, work) = try await download(installer)
        defer { try? FileManager.default.removeItem(at: work) }
        #expect(try Data(contentsOf: file).count == 40)
    }

    @Test("A redirect off the list is refused and nothing is kept")
    func redirectOffList() async throws {
        InstallerStub.serve([entry.absoluteString: .init(redirect: elsewhere),
                             elsewhere.absoluteString: .init(body: Data(repeating: 1, count: 40))])
        try await refused(installer, saying: "unexpected address")
    }

    @Test("A redirect down to plain http is refused")
    func redirectInsecure() async throws {
        let plain = URL(string: "http://static3.cdn.ubi.com/orbit/Setup.exe")!
        InstallerStub.serve([entry.absoluteString: .init(redirect: plain),
                             plain.absoluteString: .init(body: Data(repeating: 1, count: 40))])
        try await refused(installer, saying: "unexpected address")
    }

    @Test("An entry URL off the list never reaches the network")
    func entryOffList() async throws {
        InstallerStub.serve([:])
        let bad = LauncherInstaller(store: .ubisoft, url: elsewhere, hosts: installer.hosts, sizes: installer.sizes)
        try await refused(bad, saying: "unexpected address")
    }

    @Test("A file too small or too big for its bound is refused", arguments: [5, 200])
    func size(count: Int) async throws {
        InstallerStub.serve([entry.absoluteString: .init(body: Data(repeating: 1, count: count))])
        try await refused(installer, saying: "size")
    }

    @Test("A server error is a failed download, not a kept file")
    func serverError() async throws {
        InstallerStub.serve([entry.absoluteString: .init(status: 500, body: Data(repeating: 1, count: 50))])
        try await refused(installer, saying: "download")
    }
}
