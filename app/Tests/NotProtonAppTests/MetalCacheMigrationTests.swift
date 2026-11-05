import Foundation
import Testing
@testable import NotProtonApp

@Suite("Metal shader cache migration")
struct MetalCacheMigrationTests {
    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "metal-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("The old loader's cache is copied once to the new bundle ID, the old one stays")
    func copiesOnce() throws {
        let cache = try scratch()
        let old = cache.appending(path: "\(MetalCacheMigration.old)/com.apple.metal")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try Data("shaders".utf8).write(to: old.appending(path: "functions.data"))
        #expect(MetalCacheMigration.run(in: cache))
        let copied = cache.appending(path: "\(MetalCacheMigration.new)/com.apple.metal/functions.data")
        #expect(try Data(contentsOf: copied) == Data("shaders".utf8))
        #expect(FileManager.default.fileExists(atPath: old.path(percentEncoded: false)))
        #expect(!MetalCacheMigration.run(in: cache), "a second run leaves the new cache alone")
    }

    @Test("Nothing to copy, or a cache the new loader already filled: nothing happens")
    func leavesAlone() throws {
        let cache = try scratch()
        #expect(!MetalCacheMigration.run(in: cache))
        try FileManager.default.createDirectory(at: cache.appending(path: MetalCacheMigration.old), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache.appending(path: MetalCacheMigration.new), withIntermediateDirectories: true)
        #expect(!MetalCacheMigration.run(in: cache))
        #expect(MetalCacheMigration.userCacheDirectory() != nil)
    }
}
