import Foundation

public enum OfficialReleaseError: Error, Equatable, LocalizedError {
    case downloadFailed(String)
    case unreadableImage
    case noApp

    public var errorDescription: String? {
        switch self {
        case .downloadFailed:
            String(localized: "RetroArch download failed, try again later.", bundle: .module)
        case .unreadableImage, .noApp:
            String(localized: "The downloaded RetroArch could not be opened.", bundle: .module)
        }
    }
}

// The disk image is opened read-only and RetroArch.app copied out.
public struct OfficialRelease: Sendable {

    public static let versions = ["1.22.2"]

    public static let stable = URL(string: "https://buildbot.libretro.com/stable/")!

    public let paths: RetroArchPaths
    public let base: URL
    private let session: URLSession

    public init(paths: RetroArchPaths, base: URL = OfficialRelease.stable, session: URLSession = .shared) {
        self.paths = paths
        self.base = base
        self.session = session
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

        let mount = work.appending(path: "mount", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        guard Self.hdiutil(["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint",
                            mount.path(percentEncoded: false), image.path(percentEncoded: false)])
        else { throw OfficialReleaseError.unreadableImage }
        defer { _ = Self.hdiutil(["detach", "-force", mount.path(percentEncoded: false)]) }

        let found = mount.appending(path: "RetroArch.app", directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: RetroArchLaunch.binary(found).path(percentEncoded: false))
        else { throw OfficialReleaseError.noApp }

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

    static func hdiutil(_ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
