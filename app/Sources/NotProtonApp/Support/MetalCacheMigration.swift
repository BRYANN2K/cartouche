import Foundation

// Cartouche Wine 26.3.1 renamed the loader's bundle ID, and macOS keeps the Metal shader cache per bundle ID:
// copying the old folder once spares each game a full shader rebuild
enum MetalCacheMigration {
    static let old = "com.codeweavers.CrossOver.wineloader"
    static let new = "dev.bryann2k.cartouche.wineloader"

    @discardableResult
    static func run(in cache: URL? = userCacheDirectory(), files: FileManager = .default) -> Bool {
        guard let cache else { return false }
        let source = cache.appending(path: old, directoryHint: .isDirectory)
        let target = cache.appending(path: new, directoryHint: .isDirectory)
        guard files.fileExists(atPath: source.path(percentEncoded: false)),
              !files.fileExists(atPath: target.path(percentEncoded: false)) else { return false }
        do {
            // An APFS clone: no extra space
            try files.copyItem(at: source, to: target)
            AppLog.note("metal cache: copied to \(new)")
            return true
        } catch {
            try? files.removeItem(at: target)
            AppLog.note("metal cache: copy failed, games rebuild their shaders once: \(error.localizedDescription)")
            return false
        }
    }

    static func userCacheDirectory() -> URL? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard confstr(_CS_DARWIN_USER_CACHE_DIR, &buffer, buffer.count) > 0 else { return nil }
        return URL(filePath: String(cString: buffer), directoryHint: .isDirectory)
    }
}
