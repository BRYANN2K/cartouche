// Pause and Resume go to Steam through code Cartouche injects in Steam's UI: the command goes to steam-downloads.json,
// the injected page reads it from Steam's loopback host and calls SteamClient.Downloads. Cancel and Try Again are steam:// links.

import AppKit
import Foundation

@MainActor
protocol SteamDownloadControlling: AnyObject {
    func pause(appID: Int) throws
    func resume(appID: Int) throws
    func cancel(appID: Int) throws
    func retry(appID: Int) throws
}

struct SteamDownloadCommandFile: Codable, Equatable, Sendable {
    struct Command: Codable, Equatable, Sendable {
        enum Verb: String, Codable, Sendable {
            case pause, resume
        }

        let id: Int
        let appid: Int
        let verb: Verb
        // The page ignores anything older than 30 seconds
        let at: Int
    }

    var version = 1
    var commands: [Command] = []

    static let fileName = "steam-downloads.json"
    static let kept = 16
}

@MainActor
final class SteamDownloadCommands: SteamDownloadControlling {

    let file: URL
    var open: @MainActor (URL) -> Void
    var now: () -> Date = { Date() }

    init(file: URL = SupportPaths.support.appending(path: SteamDownloadCommandFile.fileName),
         open: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }) {
        self.file = file
        self.open = open
    }

    func pause(appID: Int) throws { try send(.pause, appID) }

    func resume(appID: Int) throws { try send(.resume, appID) }

    func cancel(appID: Int) throws { open(URL(string: "steam://uninstall/\(appID)")!) }

    func retry(appID: Int) throws { open(URL(string: "steam://install/\(appID)")!) }

    private func send(_ verb: SteamDownloadCommandFile.Command.Verb, _ appID: Int) throws {
        var doc = (try? JSONDecoder().decode(SteamDownloadCommandFile.self, from: Data(contentsOf: file))) ?? SteamDownloadCommandFile()
        if doc.version != 1 { doc = SteamDownloadCommandFile() }
        let next = (doc.commands.map(\.id).max() ?? 0) + 1
        doc.commands.append(.init(id: next, appid: appID, verb: verb, at: Int(now().timeIntervalSince1970)))
        doc.commands = Array(doc.commands.suffix(SteamDownloadCommandFile.kept))
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(doc).write(to: file, options: .atomic)
        AppLog.note("steam download \(verb.rawValue) \(appID), command \(next)")
    }
}
