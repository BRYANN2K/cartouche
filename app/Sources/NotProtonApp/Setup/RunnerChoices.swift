import Foundation

enum RunnerChoices {
    static func label(_ runner: Runner) -> String {
        if runner.id.hasPrefix("wine-crossover-") {
            return "Cartouche \(runner.id.dropFirst("wine-crossover-".count))"
        }
        return "\(runner.name) \(runner.displayVersion)"
    }

    static func title(id: String, name: String, version: String) -> String {
        let prefix = "wine-crossover-"
        return "\(name) \(id.hasPrefix(prefix) ? String(id.dropFirst(prefix.count)) : version)"
    }

    static func downloads(manifest: RunnerManifest, installed: [Runner], steam: Bool) -> [RunnerManifest.Build] {
        let present = Set(installed.filter(\.isInstalled).map(\.id))
        let latestCartouche = RunnerUpdate.latestCartouche(in: manifest)?.id
        return manifest.builds.filter {
            $0.kind == Runner.Kind.wineBuild.rawValue && $0.isPinned &&
                $0.cpuFlavors.contains(.rosetta) && !present.contains($0.id) &&
                (!steam || $0.origin == .cartouche) &&
                ($0.origin != .cartouche || $0.id == latestCartouche)
        }
    }
}
