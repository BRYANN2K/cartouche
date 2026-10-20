import Foundation

// libretro-thumbnails: box art, title screens and screenshots, one folder per system, files named after the database name
public enum ThumbnailKind: String, Sendable, CaseIterable {
    case boxart = "Named_Boxarts"
    case title = "Named_Titles"
    case snap = "Named_Snaps"
}

public struct Thumbnails: Sendable {

    public typealias Fetch = @Sendable (URL) async throws -> (Data, Int)

    public var base = URL(string: "https://thumbnails.libretro.com/")!
    public var cache: URL
    public var fetch: Fetch

    public init(cache: URL, fetch: @escaping Fetch = Thumbnails.download) {
        self.cache = cache
        self.fetch = fetch
    }

    public static func fileName(_ databaseName: String) -> String {
        String(databaseName.map { "&*/:`<>?\\|\"".contains($0) ? "_" : $0 })
    }

    // Every character but letters, digits and -._~ escaped, parentheses, commas and spaces included
    static func escape(_ component: String) -> String {
        var allowed = CharacterSet.alphanumerics.intersection(CharacterSet(charactersIn: Unicode.Scalar(0)..<Unicode.Scalar(128)))
        allowed.insert(charactersIn: "-._~")
        return component.addingPercentEncoding(withAllowedCharacters: allowed) ?? component
    }

    public func url(system: String, kind: ThumbnailKind, name: String) -> URL {
        URL(string: base.absoluteString + Self.escape(system) + "/" + kind.rawValue + "/" + Self.escape(Self.fileName(name)) + ".png")!
    }

    public func cached(system: String, kind: ThumbnailKind, name: String) -> URL {
        cache.appending(path: system, directoryHint: .isDirectory).appending(path: kind.rawValue, directoryHint: .isDirectory)
            .appending(path: Self.fileName(name) + ".png")
    }

    public func local(system: String, kind: ThumbnailKind, name: String) -> URL? {
        let file = cached(system: system, kind: kind, name: name)
        return FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) ? file : nil
    }

    public func isMissing(system: String, kind: ThumbnailKind, name: String) -> Bool {
        FileManager.default.fileExists(atPath: missingMark(system: system, kind: kind, name: name).path(percentEncoded: false))
    }

    func missingMark(system: String, kind: ThumbnailKind, name: String) -> URL {
        cached(system: system, kind: kind, name: name).appendingPathExtension("missing")
    }

    // The cached picture, or the downloaded one kept in the cache; nil when the project has none, or offline before the first view
    public func image(system: String, kind: ThumbnailKind, name: String) async -> URL? {
        if let found = local(system: system, kind: kind, name: name) { return found }
        guard let (data, status) = try? await fetch(url(system: system, kind: kind, name: name)) else { return nil }
        let file = cached(system: system, kind: kind, name: name)
        guard status == 200, data.starts(with: [0x89, 0x50, 0x4E, 0x47]) else {
            if status == 404 {
                try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? Data().write(to: missingMark(system: system, kind: kind, name: name))
            }
            return nil
        }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            return file
        } catch {
            return nil
        }
    }

    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config)
    }()

    @Sendable public static func download(_ url: URL) async throws -> (Data, Int) {
        let (data, response) = try await session.data(from: url)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}
