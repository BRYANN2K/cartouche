import Darwin
import Foundation
import InstallerKit

// Wine searches its builtins before WINEDLLPATH. Each renderer gets a separate
// copy-on-write engine so selecting it cannot change another game's DLLs.
enum GraphicsRunner {
    private static let lock = NSLock()
    private static let receiptName = ".cartouche-graphics.json"

    private struct Stamp: Codable, Equatable {
        let size: Int
        let modified: Double
    }
    private struct Recipe: Codable, Equatable {
        let source: String
        let files: [String: Stamp]
    }

    private static func source(_ backend: GraphicsBackend?, wine: WineRunner, backends: URL, runners: URL) -> URL? {
        guard let backend, backend != .wined3d,
              !wine.root.path.contains("/.graphics/"),
              !FileManager.default.fileExists(atPath: wine.root.appending(path: "share/crossover").path) else { return nil }
        if backend == .d3dmetal {
            return PortingToolkitSource.libd3dshared(runners: runners)?.deletingLastPathComponent().deletingLastPathComponent()
        }
        guard BackendInstaller.receipt(for: backend, in: backends) != nil else { return nil }
        return BackendInstaller.folder(for: backend, in: backends)
    }

    private static func destination(wine: WineRunner, backend: GraphicsBackend, runners: URL) -> URL {
        runners.appending(path: ".graphics/\(wine.root.lastPathComponent)/\(backend.rawValue)")
    }

    private static func recipe(wine: WineRunner, source: URL) -> Recipe {
        var files: [String: Stamp] = [:]
        var paths = [wine.loader, wine.root.appending(path: ".cartouche-runner.json"),
                     wine.root.appending(path: "lib/wine/x86_64-unix/ntdll.so")]
        paths += WineArch.allCases.map { wine.root.appending(path: "lib/wine/\($0.rawValue)/ntdll.dll") }
        for arch in BackendInstaller.folders {
            let directory = source.appending(path: arch.hasSuffix("-windows") || arch.hasSuffix("-unix") ? arch : "")
            let nested = source.appending(path: "wine/\(arch)")
            for folder in [directory, nested] {
                paths += (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            }
        }
        for file in paths {
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = values.fileSize, let date = values.contentModificationDate else { continue }
            files[file.path] = Stamp(size: size, modified: date.timeIntervalSince1970)
        }
        return Recipe(source: wine.root.path, files: files)
    }

    private static func mapped(_ wine: WineRunner, to root: URL) -> WineRunner {
        func map(_ url: URL) -> URL {
            root.appending(path: String(url.path.dropFirst(wine.root.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        }
        return WineRunner(root: root, loader: map(wine.loader), server: map(wine.server),
                          dllPath: wine.dllPath.replacingOccurrences(of: wine.root.path, with: root.path))
    }

    static func cached(_ wine: WineRunner, backend: GraphicsBackend?, backends: URL, runners: URL) -> WineRunner {
        guard let backend, let source = source(backend, wine: wine, backends: backends, runners: runners) else { return wine }
        let root = destination(wine: wine, backend: backend, runners: runners)
        guard JSONFile.load(Recipe.self, from: root.appending(path: receiptName)) == recipe(wine: wine, source: source),
              FileManager.default.isExecutableFile(atPath: mapped(wine, to: root).loader.path) else { return wine }
        return mapped(wine, to: root)
    }

    static func prepare(_ wine: WineRunner, backend: GraphicsBackend?, backends: URL, runners: URL) throws -> WineRunner {
        guard let backend, let source = source(backend, wine: wine, backends: backends, runners: runners) else { return wine }
        return try lock.withLock {
            let current = cached(wine, backend: backend, backends: backends, runners: runners)
            if current.root != wine.root { return current }
            let root = destination(wine: wine, backend: backend, runners: runners)
            let staging = root.deletingLastPathComponent().appending(path: ".\(backend.rawValue)-\(UUID().uuidString)")
            let fm = FileManager.default
            try fm.createDirectory(at: staging.deletingLastPathComponent(), withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: staging) }
            let result = wine.root.withUnsafeFileSystemRepresentation { from in
                staging.withUnsafeFileSystemRepresentation { to in
                    copyfile(from, to, nil, copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_CLONE))
                }
            }
            guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            if backend == .d3dmetal {
                let external = staging.appending(path: "lib/external")
                try? fm.removeItem(at: external)
                try fm.createDirectory(at: external.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.createSymbolicLink(at: external, withDestinationURL: source.appending(path: "external"))
            }
            for arch in BackendInstaller.folders {
                let from = source.appending(path: backend == .d3dmetal ? "wine/\(arch)" : arch)
                let to = staging.appending(path: "lib/wine/\(arch)")
                for file in (try? fm.contentsOfDirectory(at: from, includingPropertiesForKeys: nil)) ?? [] {
                    guard ["dll", "so"].contains(file.pathExtension) else { continue }
                    try fm.createDirectory(at: to, withIntermediateDirectories: true)
                    let target = to.appending(path: file.lastPathComponent)
                    try? fm.removeItem(at: target)
                    try fm.copyItem(at: file, to: target)
                }
            }
            if backend == .d3dmetal {
                let unix = staging.appending(path: "lib/wine/x86_64-unix")
                try fm.createDirectory(at: unix, withIntermediateDirectories: true)
                for name in PortingToolkitSource.graphicsDLLs where fm.fileExists(atPath: source.appending(path: "wine/x86_64-windows/\(name).dll").path) {
                    let target = unix.appending(path: "\(name).so")
                    try? fm.removeItem(at: target)
                    try fm.createSymbolicLink(atPath: target.path, withDestinationPath: "../../external/libd3dshared.dylib")
                }
            }
            try JSONEncoder().encode(recipe(wine: wine, source: source)).write(to: staging.appending(path: receiptName))
            try swapIn(staging, at: root)
            return mapped(wine, to: root)
        }
    }
}
