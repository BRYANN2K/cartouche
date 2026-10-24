
import Foundation

struct FreeRunnerScan: Sendable {
    var manifest: RunnerManifest
    var toolkits: [PortingToolkitInstall] = []

    static var standard: FreeRunnerScan {
        FreeRunnerScan(manifest: .current(), toolkits: PortingToolkitSource.discover())
    }

    func runners(runners: URL, fexAvailable: Bool) -> [Runner] {
        WineRunnerSource.runners(manifest: manifest, runners: runners, fexAvailable: fexAvailable)
            + PortingToolkitSource.runners(found: toolkits, runners: runners)
    }
}

enum WineRunnerSource {

    static func runners(manifest: RunnerManifest, runners: URL, fexAvailable: Bool) -> [Runner] {
        var listed: [Runner] = manifest.builds.map { build in
            let installed = WineRunnerInstaller.isInstalled(build.id, runners: runners)
            let problems = installed ? WineRunnerInstaller.verify(build.id, runners: runners) : []
            let state: Runner.State = !installed ? .available : problems.isEmpty ? .ready : .damaged(files: problems)
            return Runner(
                id: build.id, kind: .wineBuild, version: build.version, displayVersion: build.displayVersion,
                flavors: build.cpuFlavors.filter { $0 != .fex || fexAvailable },
                state: state, build: nil, source: nil, isInstalled: installed
            )
        }
        let pinned = Set(manifest.builds.map(\.id))
        for id in installedIDs(in: runners) where !pinned.contains(id) {
            listed.append(Runner(
                id: id, kind: .wineBuild, version: id, displayVersion: id, flavors: [],
                state: .unsupported(reason: String(localized: "Build \(id)") + String(localized: ", not supported")),
                build: nil, source: nil, isInstalled: false
            ))
        }
        return listed
    }

    // Receipts name the build; the folder may be the id or the older wine-<id> shape
    static func installedIDs(in runners: URL) -> [String] {
        let entries = (try? FileManager.default.contentsOfDirectory(at: runners, includingPropertiesForKeys: nil)) ?? []
        var ids: Set<String> = []
        for folder in entries {
            let file = folder.appending(path: WineRunnerInstaller.receiptName)
            guard let receipt = (try? Data(contentsOf: file))
                .flatMap({ try? JSONDecoder().decode(WineRunnerInstaller.Receipt.self, from: $0) })
            else { continue }
            ids.insert(receipt.id)
        }
        return ids.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
