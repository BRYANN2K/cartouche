import CryptoKit
import Foundation

public struct BIOSFile: Sendable, Equatable, Identifiable {
    public enum State: Sendable, Equatable {
        case found
        case missing
        case wrongFile
    }

    public var name: String
    public var description: String
    public var md5: String?
    public var needed: Bool
    public var state: State

    public var id: String { name }
}

// What a console's games need from the BIOS folder. It names files and MD5s only: Cartouche never offers a BIOS download.
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
        case .wrongFile(let name):
            if let md5 = files.first(where: { $0.name == name })?.md5 {
                String(localized: "\(name) is not the expected file (expected MD5: \(md5)).", bundle: .module)
            } else {
                String(localized: "\(name) is not the expected file", bundle: .module)
            }
        }
    }

    public var isReady: Bool { summary == .notNeeded || summary == .found }
}

public struct BIOSChecker: Sendable {

    public let paths: RetroArchPaths

    public init(paths: RetroArchPaths) { self.paths = paths }

    public func status(for console: Console, core: String? = nil) -> BIOSStatus {
        let core = core ?? console.core
        let info = CoreInfo.load(paths.coreInfo.appending(path: "\(core)_libretro.info"))
        let accepted: [String]
        switch console.bios {
        case .none: accepted = []
        case .oneOf(let names):
            // PCSX ReARMed can run with its built-in HLE BIOS. Other PS1 cores
            // still need a BIOS, using the filenames their own info advertises.
            if console.id == "ps1", core == "pcsx_rearmed" {
                accepted = []
            } else if console.id == "ps1", let firmware = info?.firmware, !firmware.isEmpty {
                let listed = firmware.map(\.path)
                accepted = names.filter { listed.contains($0) } + listed.filter { !names.contains($0) }
            } else {
                accepted = names
            }
        }

        var files = (info?.firmware ?? []).map { firmware in
            BIOSFile(
                name: firmware.path, description: firmware.description, md5: firmware.md5,
                needed: !firmware.optional || accepted.contains(firmware.path),
                state: state(of: firmware.path, md5: firmware.md5))
        }
        for name in accepted where !files.contains(where: { $0.name == name }) {
            files.append(BIOSFile(name: name, description: name, md5: nil, needed: true, state: state(of: name, md5: nil)))
        }

        // SwanStation detects OpenBIOS by this header rather than a fixed MD5,
        // and searches every file in system_directory (including renamed BIOSes).
        if console.id == "ps1", core == "swanstation" {
            let candidates = (try? FileManager.default.contentsOfDirectory(
                at: paths.bios, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])) ?? []
            for url in candidates.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where Self.isOpenBIOS(url) {
                let name = url.lastPathComponent
                files.removeAll { $0.name == name }
                files.append(BIOSFile(name: name, description: "OpenBIOS", md5: nil, needed: true, state: .found))
                return BIOSStatus(console: console, summary: .found, files: files)
            }
        }
        return BIOSStatus(console: console, summary: summary(files, accepted: accepted), files: files)
    }

    private static func isOpenBIOS(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, values.fileSize == 512 * 1024,
              let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: 0x78)
            return try handle.read(upToCount: 8) == Data("OpenBIOS".utf8)
        } catch { return false }
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
