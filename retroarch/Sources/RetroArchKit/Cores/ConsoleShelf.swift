import Foundation

// The consoles the user added. Adding one downloads its recommended core;
// removing one deletes the cores no other added console uses. Game files are
// never part of either.
public actor ConsoleShelf {

    public let paths: RetroArchPaths
    public let cores: CoreManager

    public init(paths: RetroArchPaths, cores: CoreManager) {
        self.paths = paths
        self.cores = cores
    }

    public func added() -> [Console] {
        let ids = (try? Data(contentsOf: paths.consoles))
            .flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        return ConsoleCatalog.all.filter { ids.contains($0.id) }
    }

    public func add(_ id: String) async throws {
        guard let console = ConsoleCatalog.console(id) else { return }
        try await cores.install(console.core)
        try save(Set(added().map(\.id)).union([id]))
    }

    public func remove(_ id: String) async throws {
        guard let console = ConsoleCatalog.console(id) else { return }
        let remaining = added().filter { $0.id != id }
        try save(Set(remaining.map(\.id)))
        if !remaining.contains(where: { $0.core == console.core }) {
            try await cores.delete(console.core)
        }
    }

    private func save(_ ids: Set<String>) throws {
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        try JSONEncoder().encode(ids.sorted()).write(to: paths.consoles, options: .atomic)
    }
}
