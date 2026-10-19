import Foundation
import Network
import Synchronization

// Games hosted on the local network, found over Bonjour as RetroArch for
// macOS publishes them. Browsing is a local network use: the app asks for
// Local Network before it calls this.
public enum LocalNetplayBrowser {

    public static func rooms(within limit: Duration = .seconds(2)) async -> [NetplayRoom] {
        let found = Mutex<[NWBrowser.Result]>([])
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: LocalNetplay.serviceType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { results, _ in found.withLock { $0 = Array(results) } }
        browser.start(queue: .global(qos: .userInitiated))
        try? await Task.sleep(for: limit)
        browser.cancel()

        // Resolving one host can take its timeout: all at once, not in turn
        let results = found.withLock { $0 }
        return await withTaskGroup(of: NetplayRoom?.self) { group in
            for result in results {
                group.addTask {
                    guard case .bonjour(let record) = result.metadata,
                          let (address, port) = await resolve(result.endpoint)
                    else { return nil }
                    return LocalNetplay.room(txt: record.dictionary, address: address, port: port)
                }
            }
            var rooms: [NetplayRoom] = []
            for await room in group.compactMap({ $0 }) { rooms.append(room) }
            return rooms
        }
    }

    // The host's address and port. Network resolves a service only on the way
    // to connecting, so the connection is dropped as soon as the path names
    // them; RetroArch sees a peer that left before saying hello.
    static func resolve(_ endpoint: NWEndpoint) async -> (String, UInt16)? {
        let connection = NWConnection(to: endpoint, using: .tcp)
        let answer = Mutex<CheckedContinuation<(String, UInt16)?, Never>?>(nil)
        @Sendable func finish(_ value: (String, UInt16)?) {
            answer.withLock { $0?.resume(returning: value); $0 = nil }
            connection.cancel()
        }
        return await withCheckedContinuation { continuation in
            answer.withLock { $0 = continuation }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if case .hostPort(let host, let port)? = connection.currentPath?.remoteEndpoint {
                        var address = "\(host)"
                        // A scoped IPv6 address carries its interface after %
                        if let cut = address.firstIndex(of: "%") { address = String(address[..<cut]) }
                        finish((address, port.rawValue))
                    } else {
                        finish(nil)
                    }
                case .failed, .cancelled, .waiting: finish(nil)
                default: break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { finish(nil) }
        }
    }
}
