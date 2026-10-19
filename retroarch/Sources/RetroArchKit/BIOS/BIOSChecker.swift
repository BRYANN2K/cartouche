import CryptoKit
import Foundation

// One BIOS file a core can use, and what the BIOS folder holds for it
public struct BIOSFile: Sendable, Equatable, Identifiable {
    public enum State: Sendable, Equatable {
        case found
        case missing
        // There, but its MD5 is not the one the core expects
        case wrongFile
    }

    public var name: String
    public var description: String
    public var md5: String?
    public var needed: Bool
    public var state: State

    public var id: String { name }
}

// What a console's games need from the BIOS folder. It names files and MD5s
// only: Cartouche never offers a BIOS download.
public struct BIOSStatus: Sendable, Equatable {
    public enum Summary: Sendable, Equatable {
        case notNeeded
        case found
        case missing(String)
        case wrongFile(String)
    }

    public var console: Console
    public var summary: Summary
    public var files: [BIOSFile]

    public var message: String {
        switch summary {
        case .notNeeded: String(localized: "No BIOS needed", bundle: .module)
        case .found: String(localized: "BIOS found", bundle: .module)
        case .missing(let name): String(localized: "\(name) is missing", bundle: .module)
        case .wrongFile(let name): String(localized: "\(name) is not the expected file", bundle: .module)
        }
    }

    public var isReady: Bool { summary == .notNeeded || summary == .found }
}

public struct BIOSChecker: Sendable {

    public let paths: RetroArchPaths

    public init(paths: RetroArchPaths) { self.paths = paths }

    public func status(for console: Console) -> BIOSStatus {
        let info = CoreInfo.load(paths.coreInfo.appending(path: "\(console.core)_libretro.info"))
        let accepted: [String]
        switch console.bios {
        case .none: accepted = []
        case .oneOf(let names): accepted = names
        }

        var files = (info?.firmware ?? []).map { firmware in
            BIOSFile(
                name: firmware.path, description: firmware.description, md5: firmware.md5,
                needed: !firmware.optional || accepted.contains(firmware.path),
                state: state(of: firmware.path, md5: firmware.md5))
        }
        // Named by the console's rule though the .info file is not here yet
        for name in accepted where !files.contains(where: { $0.name == name }) {
            files.append(BIOSFile(name: name, description: name, md5: nil, needed: true, state: state(of: name, md5: nil)))
        }

        return BIOSStatus(console: console, summary: summary(files, accepted: accepted), files: files)
    }

    private func summary(_ files: [BIOSFile], accepted: [String]) -> BIOSStatus.Summary {
        if !accepted.isEmpty {
            let candidates = accepted.compactMap { name in files.first { $0.name == name } }
            if candidates.contains(where: { $0.state == .found }) { return .found }
            if let wrong = candidates.first(where: { $0.state == .wrongFile }) { return .wrongFile(wrong.name) }
            return .missing(accepted[0])
        }
        let needed = files.filter(\.needed)
        if needed.isEmpty { return .notNeeded }
        if let wrong = needed.first(where: { $0.state == .wrongFile }) { return .wrongFile(wrong.name) }
        if let missing = needed.first(where: { $0.state == .missing }) { return .missing(missing.name) }
        return .found
    }

    private func state(of name: String, md5: String?) -> BIOSFile.State {
        let url = paths.bios.appending(path: name)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return .missing }
        guard let md5 else { return .found }
        return (try? Self.md5(url)) == md5 ? .found : .wrongFile
    }

    static func md5(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = Insecure.MD5()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
