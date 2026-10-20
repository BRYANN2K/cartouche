
import Foundation

enum CrossOverSupport: Sendable, Equatable {
    case supported(RunnerBuild)
    case unsupportedBuild(String)
    case unreadable
}

struct CrossOverInstall: Sendable, Identifiable {
    let bundle: URL
    let releaseVersion: String?
    let support: CrossOverSupport

    var isManual = false

    var id: String { bundle.path(percentEncoded: false) }
    var name: String { bundle.deletingPathExtension().lastPathComponent }
    var crossOverRoot: URL { SupportPaths.crossOverRoot(inBundle: bundle) }

    var isPreview: Bool { name.localizedCaseInsensitiveContains("Preview") }

    var isUsable: Bool {
        if case .supported = support { return true }
        return false
    }
}

enum CrossOverSource {

    static let searchRoots: [URL] = [
        URL(filePath: "/Applications", directoryHint: .isDirectory),
        SupportPaths.home.appending(path: "Applications", directoryHint: .isDirectory),
    ]

    private static let manualKey = "manualCrossOverPaths"
    private static let legacyManualKey = "manualCrossOverPath"

    static func manualBundles(_ defaults: UserDefaults = .standard) -> [URL] {
        let paths = defaults.stringArray(forKey: manualKey)
            ?? defaults.string(forKey: legacyManualKey).map { [$0] } ?? []
        return paths.filter { !$0.isEmpty }.map { URL(filePath: $0, directoryHint: .isDirectory) }
    }

    static func setManualBundles(_ bundles: [URL], _ defaults: UserDefaults = .standard) {
        defaults.set(bundles.map { $0.path(percentEncoded: false) }, forKey: manualKey)
        defaults.removeObject(forKey: legacyManualKey)
    }

    static func addManualBundle(_ bundle: URL, _ defaults: UserDefaults = .standard) {
        let current = manualBundles(defaults)
        guard !current.contains(where: { same($0, bundle) }) else { return }
        setManualBundles(current + [bundle], defaults)
    }

    static func removeManualBundle(_ bundle: URL, _ defaults: UserDefaults = .standard) {
        setManualBundles(manualBundles(defaults).filter { !same($0, bundle) }, defaults)
    }

    static func isSearched(_ bundle: URL, roots: [URL] = searchRoots) -> Bool {
        let parent = bundle.standardizedFileURL.deletingLastPathComponent()
        return roots.contains { same($0, parent) }
    }

    static func same(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.path(percentEncoded: false) == b.standardizedFileURL.path(percentEncoded: false)
    }

    static func looksLikeCrossOver(_ bundle: URL) -> Bool {
        let root = SupportPaths.crossOverRoot(inBundle: bundle)
        return FileManager.default.fileExists(
            atPath: root.appending(path: "lib/wine").path(percentEncoded: false)
        )
    }

    static func discover(
        roots: [URL] = searchRoots, manual: [URL] = manualBundles(), pins: [RunnerBuild] = SupportedRunners.all
    ) -> [CrossOverInstall] {
        let fm = FileManager.default
        var found: [CrossOverInstall] = []
        var seen: Set<String> = []

        func consider(_ bundle: URL, isManual: Bool) {
            let key = bundle.standardizedFileURL.path(percentEncoded: false)
            guard !seen.contains(key), looksLikeCrossOver(bundle) else { return }
            seen.insert(key)
            found.append(inspect(bundle: bundle, isManual: isManual, pins: pins))
        }

        for bundle in manual where !isSearched(bundle, roots: roots) { consider(bundle, isManual: true) }

        for root in roots {
            let entries = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            for entry in entries where entry.pathExtension == "app" {
                guard entry.deletingPathExtension().lastPathComponent.hasPrefix("CrossOver") else { continue }
                consider(entry, isManual: false)
            }
        }

        return found.sorted(by: preferred)
    }

    static func preferred(_ a: CrossOverInstall, _ b: CrossOverInstall) -> Bool {
        if a.isManual != b.isManual { return a.isManual }
        if a.isUsable != b.isUsable { return a.isUsable }
        if a.isPreview != b.isPreview { return a.isPreview }
        if a.name != b.name { return a.name < b.name }
        return a.id < b.id
    }

    static func inspect(
        bundle: URL, isManual: Bool = false, pins: [RunnerBuild] = SupportedRunners.all
    ) -> CrossOverInstall {
        guard let version = releaseVersion(of: bundle) else {
            return CrossOverInstall(bundle: bundle, releaseVersion: nil, support: .unreadable, isManual: isManual)
        }
        guard let hash = Digest.sha256IfPresent(unixLoader(inBundle: bundle)) else {
            return CrossOverInstall(
                bundle: bundle, releaseVersion: version, support: .unreadable, isManual: isManual
            )
        }

        guard let build = SupportedRunners.build(loaderSHA256: hash, in: pins) else {
            return CrossOverInstall(
                bundle: bundle, releaseVersion: version,
                support: .unsupportedBuild(version), isManual: isManual
            )
        }

        return CrossOverInstall(
            bundle: bundle, releaseVersion: version, support: .supported(build), isManual: isManual
        )
    }

    // CrossOver puts the build date here and the version number in CFBundleVersion, so this is the string its download page shows.
    static func releaseVersion(of bundle: URL) -> String? {
        let plist = bundle.appending(path: "Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = object as? [String: Any]
        else { return nil }
        return dict["CFBundleShortVersionString"] as? String
    }

    static func unixLoader(inBundle bundle: URL) -> URL {
        unixLoader(inRoot: SupportPaths.crossOverRoot(inBundle: bundle))
    }

    static func unixLoader(inRoot root: URL) -> URL {
        root.appending(path: "lib/wine/x86_64-unix/wine")
    }

    static func verifyPatchInputs(root: URL, build: RunnerBuild) throws {
        for arch in WineArch.allCases {
            guard let expected = build.cleanNtdll[arch] else { continue }
            let ntdll = NtdllPatcher.cleanSource(inRoot: root, arch: arch)
            guard let actual = Digest.sha256IfPresent(ntdll) else {
                throw StepFailure(
                    step: String(localized: "Verify CrossOver"),
                    detail: String(localized: "\(arch.rawValue)/ntdll.dll is missing from \(root.path(percentEncoded: false)).")
                )
            }
            guard actual == expected else {
                throw StepFailure(
                    step: String(localized: "Verify CrossOver"),
                    detail: String(localized: "\(arch.rawValue)/\(ntdll.lastPathComponent) is not the build \(build.bundleVersion) copy. Expected \(expected.prefix(16)), found \(actual.prefix(16)).")
                )
            }
        }
    }
}

extension CrossOverSource {

    static let missingWine = String(localized: "The clone has no Wine loader at \("lib/wine").")

    // One runner per CrossOver build, in the order the Status pane lists them: copies found on disk, then clones whose copy is gone, then clones no longer pinned.
    static func runners(
        installs: [CrossOverInstall], installed: [RunnerBuild], damaged: [String], orphaned: [String],
        problems: [String: [String]], pins: [RunnerBuild] = SupportedRunners.all,
        fexAvailable: Bool = CompatTool.Flavor.fexAvailable
    ) -> [Runner] {
        var runners: [Runner] = []
        var seen: Set<String> = []

        func runner(_ build: RunnerBuild, source: URL?) -> Runner {
            let clone = installed.first { $0.id == build.id }
            let state: Runner.State
            if clone != nil {
                let found = problems[build.id] ?? []
                state = found.isEmpty ? .ready : .damaged(files: found)
            } else if damaged.contains(build.id) {
                state = .damaged(files: [missingWine])
            } else {
                state = .available
            }
            // A clone can be a rebuild of the pinned build, with its own hashes.
            let pinned = clone ?? build
            return Runner(
                id: build.id, kind: .crossOver, version: pinned.bundleVersion,
                displayVersion: pinned.displayVersion,
                flavors: Runner.flavors(of: pinned, fexAvailable: fexAvailable),
                state: state, build: pinned, source: source, isInstalled: clone != nil
            )
        }

        func unsupported(id: String, version: String, reason: String, source: URL?) -> Runner {
            Runner(
                id: id, kind: .crossOver, version: version, displayVersion: version, flavors: [],
                state: .unsupported(reason: reason), build: nil, source: source, isInstalled: false
            )
        }

        for install in installs {
            switch install.support {
            case .supported(let build):
                guard seen.insert(build.id).inserted else { continue }
                runners.append(runner(build, source: install.bundle))
            case .unsupportedBuild(let version):
                runners.append(unsupported(
                    id: install.id, version: version,
                    reason: String(localized: "Version \(version) not supported (supported: \(SupportedRunners.versionList))"),
                    source: install.bundle
                ))
            case .unreadable:
                continue
            }
        }
        for build in installed where seen.insert(build.id).inserted {
            runners.append(runner(build, source: nil))
        }
        for id in damaged where seen.insert(id).inserted {
            guard let build = SupportedRunners.build(id: id, in: pins) else { continue }
            runners.append(runner(build, source: nil))
        }
        for id in orphaned where seen.insert(id).inserted {
            runners.append(unsupported(
                id: id, version: id,
                reason: String(localized: "Build \(id)") + String(localized: ", not supported"),
                source: nil
            ))
        }
        return runners
    }
}
