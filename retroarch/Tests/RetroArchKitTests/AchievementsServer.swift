import Foundation
import Network
import Synchronization

// A RetroAchievements stand-in on 127.0.0.1: dorequest.php answers each
// request by its r= with the JSON rcheevos reads, so a real RetroArch can
// sign in and load a game without the real site. No real account is used.
final class AchievementsServer: Sendable {

    struct Request: Sendable {
        let fields: [String: String]
        var r: String { fields["r"] ?? "" }
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "achievements-server")
    private let state = Mutex<[Request]>([])
    let token: String
    // A Rich Presence script for the coach: the test core keeps its frame count at 0
    let richPresence: String

    let knownHash: String

    init(token: String = "tok-\(UUID().uuidString.prefix(8))", knownHash: String = "",
         richPresence: String = "Lookup:Mode\n0=Title\n1=Playing\n\nDisplay:\nFrame @Frames(0xX0000), @Mode(0xH0100)") throws {
        self.token = token
        self.knownHash = knownHash
        self.richPresence = richPresence
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> URL {
        let ready = Mutex<CheckedContinuation<Void, Error>?>(nil)
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            ready.withLock { $0 = continuation }
            listener.stateUpdateHandler = { update in
                switch update {
                case .ready: ready.withLock { $0?.resume(); $0 = nil }
                case .failed(let error): ready.withLock { $0?.resume(throwing: error); $0 = nil }
                default: break
                }
            }
            listener.start(queue: queue)
        }
        return URL(string: "http://127.0.0.1:\(listener.port!.rawValue)")!
    }

    func stop() { listener.cancel() }

    var requests: [Request] { state.withLock { $0 } }

    static func form(_ body: String) -> [String: String] {
        var out: [String: String] = [:]
        for pair in body.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
            out[parts[0]] = parts.count > 1 ? parts[1] : ""
        }
        return out
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, Data())
    }

    private func receive(_ connection: NWConnection, _ buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if done || error != nil { connection.cancel() } else { self.receive(connection, buffer) }
                return
            }
            let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
            let length = head.split(separator: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
                .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
            let body = buffer[end.upperBound...]
            if body.count < length, !done, error == nil {
                self.receive(connection, buffer)
                return
            }
            let path = head.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            self.respond(connection, path: path, body: String(decoding: body, as: UTF8.self))
        }
    }

    private func respond(_ connection: NWConnection, path: String, body: String) {
        var payload = Data()
        var code = 404
        if path.hasPrefix("/dorequest.php") {
            var fields = Self.form(body)
            if let query = path.split(separator: "?", maxSplits: 1).dropFirst().first {
                fields.merge(Self.form(String(query))) { a, _ in a }
            }
            let request = Request(fields: fields)
            state.withLock { $0.append(request) }
            code = 200
            payload = Data(answer(request).utf8)
        }
        var response = Data("HTTP/1.1 \(code) X\r\nContent-Type: application/json\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n".utf8)
        response.append(payload)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func answer(_ request: Request) -> String {
        let user = request.fields["u"] ?? ""
        let signedIn = request.fields["t"] == token
        switch request.r {
        case "login2":
            guard request.fields["p"] == "correct horse" || signedIn else {
                return #"{"Success":false,"Error":"Invalid User/Password combination. Please try again","Code":"invalid_credentials"}"#
            }
            return #"{"Success":true,"User":"\#(user)","AvatarUrl":"","Token":"\#(token)","Score":0,"SoftcoreScore":0,"Messages":0,"Permissions":1,"AccountType":"Registered"}"#
        case "gameid":
            return #"{"Success":true,"GameID":\#(request.fields["m"] == knownHash ? 4242 : 0)}"#
        case "allprogress":
            guard signedIn else { return #"{"Success":false,"Error":"Invalid token","Code":"invalid_credentials"}"# }
            return #"{"Success":true,"Response":{"4242":{"Achievements":64,"Unlocked":12,"UnlockedHardcore":7},"77":{"Achievements":20,"Unlocked":20,"UnlockedHardcore":0}}}"#
        case "patch":
            let script = richPresence.replacingOccurrences(of: "\n", with: "\\n")
            return #"{"Success":true,"PatchData":{"ID":4242,"Title":"Cartouche Test","ConsoleID":4,"ImageIcon":"/Images/000001.png","RichPresencePatch":"\#(script)","Achievements":[],"Leaderboards":[]}}"#
        case "achievementsets":
            let script = richPresence.replacingOccurrences(of: "\n", with: "\\n")
            return #"""
            {"Success":true,"GameId":4242,"Title":"Cartouche Test","ConsoleId":4,"ImageIconUrl":"http://127.0.0.1/Images/000001.png",
             "RichPresenceGameId":4242,"RichPresencePatch":"\#(script)",
             "Sets":[{"AchievementSetId":1,"GameId":4242,"Title":"Cartouche Test","Type":"core","ImageIconUrl":"http://127.0.0.1/Images/000001.png",
               "Achievements":[{"ID":101,"Title":"Far Away","Description":"Never reached in a test","Flags":3,"Points":5,"MemAddr":"0xX0000=4000000000",
                 "Author":"cartouche","BadgeName":"00001","Created":1700000000,"Modified":1700000000,"Type":"","Rarity":50.0,"RarityHardcore":25.0,
                 "BadgeURL":"http://127.0.0.1/Badge/00001.png","BadgeLockedURL":"http://127.0.0.1/Badge/00001_lock.png"}],
               "Leaderboards":[]}]}
            """#
        case "startsession":
            return #"{"Success":true,"Unlocks":[],"HardcoreUnlocks":[],"ServerNow":1700000000}"#
        default:
            return #"{"Success":true}"#
        }
    }

}
