import Foundation

public enum OfficialReleaseError: Error, Equatable, LocalizedError {
    case downloadFailed(String)
    case unreadableImage
    case noApp
    case unverified

    public var errorDescription: String? {
        switch self {
        case .downloadFailed:
            String(localized: "RetroArch download failed, try again later.", bundle: .module)
        case .unreadableImage, .noApp:
            String(localized: "The downloaded RetroArch could not be opened.", bundle: .module)
        case .unverified:
            String(localized: "This RetroArch could not be verified, so it was not installed.", bundle: .module)
        }
    }
}

public struct ReleasePin: Sendable, Equatable {
    public let size: Int64
    public let sha256: String

    public init(size: Int64, sha256: String) {
        self.size = size
        self.sha256 = sha256
    }
}

// The disk image must match its pinned size and SHA-256 and the app inside must carry libretro's
// Developer ID signature; only then is it copied out of the read-only mount.
public struct OfficialRelease: Sendable {

    public static let pins: [String: ReleasePin] = [
        "1.22.2": ReleasePin(size: 232_801_022, sha256: "81b79121ba26d539064ae13b4d0419a120c3d165afbe656cf5f5412b15fdb434"),
    ]

    public static let versions = pins.keys.sorted()

    public static let stable = URL(string: "https://buildbot.libretro.com/stable/")!

    // Daniel De Matteis (libretro), the Developer ID team that signs the stable macOS builds
    public static let teamID = "UK699V5ZS8"

    public let paths: RetroArchPaths
    public let base: URL
    private let session: URLSession
    private let pins: [String: ReleasePin]
    private let signed: @Sendable (URL) -> Bool

    public init(paths: RetroArchPaths, base: URL = OfficialRelease.stable, session: URLSession = .shared,
                pins: [String: ReleasePin] = OfficialRelease.pins,
                signed: @escaping @Sendable (URL) -> Bool = { OfficialRelease.signedByLibretro($0) }) {
        self.paths = paths
        self.base = base
        self.session = session
        self.pins = pins
        self.signed = signed
    }

    public func url(_ version: String) -> URL {
        base.appending(path: "\(version)/apple/osx/universal/RetroArch_Metal.dmg")
    }

    public func app(_ version: String) -> URL {
        paths.builds.appending(path: "official-\(version)/RetroArch.app", directoryHint: .isDirectory)
    }

    public func isInstalled(_ version: String) -> Bool {
        FileManager.default.fileExists(atPath: RetroArchLaunch.binary(app(version)).path(percentEncoded: false))
    }

    @discardableResult
    public func install(_ version: String) async throws -> URL {
        if isInstalled(version) { return app(version) }
        guard let pin = pins[version] else { throw OfficialReleaseError.unverified }
        let work = paths.downloads.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let image = work.appending(path: "RetroArch.dmg")
        do {
            let (body, response) = try await session.download(from: url(version))
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw OfficialReleaseError.downloadFailed("HTTP \(http.statusCode)")
            }
            try FileManager.default.moveItem(at: body, to: image)
        } catch let error as OfficialReleaseError {
            throw error
        } catch {
            throw OfficialReleaseError.downloadFailed(error.localizedDescription)
        }

        // Hashing, hdiutil, codesign and ditto are long or wait on processes: never on the caller's actor
        return try await Task.detached { try self.mountCopy(version, image: image, work: work, pin: pin) }.value
    }

    static func matches(_ image: URL, _ pin: ReleasePin) -> Bool {
        guard let size = try? image.resourceValues(forKeys: [.fileSizeKey]).fileSize, Int64(size) == pin.size
        else { return false }
        return (try? CoreManager.sha256(image)) == pin.sha256.lowercased()
    }

    private func mountCopy(_ version: String, image: URL, work: URL, pin: ReleasePin) throws -> URL {
        // Only ever called from a detached task; a direct call on the main actor traps in debug builds
        assert(!Thread.isMainThread, "hdiutil and ditto wait on processes; they never run on the main actor")
        guard Self.matches(image, pin) else { throw OfficialReleaseError.unverified }
        let mount = work.appending(path: "mount", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        guard Self.hdiutil(["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint",
                            mount.path(percentEncoded: false), image.path(percentEncoded: false)])
        else { throw OfficialReleaseError.unreadableImage }
        defer { _ = Self.hdiutil(["detach", "-force", mount.path(percentEncoded: false)]) }

        let found = mount.appending(path: "RetroArch.app", directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: RetroArchLaunch.binary(found).path(percentEncoded: false))
        else { throw OfficialReleaseError.noApp }
        guard signed(found) else { throw OfficialReleaseError.unverified }

        let target = app(version)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = [found.path(percentEncoded: false), target.path(percentEncoded: false)]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else { throw OfficialReleaseError.noApp }
        return target
    }

    // A valid, strict signature over the whole bundle, from a Developer ID certificate of libretro's team
    public static func signedByLibretro(_ app: URL) -> Bool {
        let requirement = "=anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6]"
            + " and certificate leaf[field.1.2.840.113635.100.6.1.13]"
            + " and certificate leaf[subject.OU] = \"\(teamID)\""
        return run("/usr/bin/codesign", ["--verify", "--strict", "--deep", "-R", requirement, app.path(percentEncoded: false)])
    }

    static func hdiutil(_ arguments: [String]) -> Bool {
        run("/usr/bin/hdiutil", arguments)
    }

    static func run(_ tool: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
