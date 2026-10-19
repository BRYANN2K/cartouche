// Finds a Game Porting Toolkit the user installed from Apple's disk image and
// copies it into runners/gptk-<version> on this Mac. Cartouche never ships or
// downloads any of its files: Apple's license does not allow redistribution.

import Foundation

struct PortingToolkitInstall: Sendable, Equatable, Identifiable {
    // The folder holding external/D3DMetal.framework (redist/lib on Apple's image)
    let lib: URL
    // D3DMetal.framework's CFBundleShortVersionString, for example 4.0b3
    let version: String
    // What the user installed: the mounted image, an app or a folder they picked
    let origin: URL

    var id: String { PortingToolkitSource.runnerID(version: version) }
}

enum PortingToolkitSource {

    static let howToGetIt = URL(string: "https://developer.apple.com/games/game-porting-toolkit/")!
    static let step = String(localized: "Copy Game Porting Toolkit")

    struct Search: Sendable {
        // Apple's "Evaluation environment for Windows games" image mounts here with redist/lib
        var volumes = URL(filePath: "/Volumes", directoryHint: .isDirectory)
        // Copies wrapped in an app, such as Gcenx's Game Porting Toolkit.app
        var applications: [URL] = [
            URL(filePath: "/Applications", directoryHint: .isDirectory),
            SupportPaths.home.appending(path: "Applications", directoryHint: .isDirectory),
        ]
        // Version 1 was installed as a Homebrew formula, with redist/lib copied into its lib
        var homebrew: [URL] = [
            URL(filePath: "/usr/local/opt/game-porting-toolkit", directoryHint: .isDirectory),
            URL(filePath: "/opt/homebrew/opt/game-porting-toolkit", directoryHint: .isDirectory),
        ]
        var manual: [URL] = PortingToolkitSource.manualFolders()

        static var standard: Search { Search() }
    }

    struct Receipt: Sendable, Equatable, Codable {
        let version: String
        let origin: String
        let files: [String: String]
    }

    static let receiptName = ".cartouche-runner.json"
    private static let manualKey = "manualPortingToolkitPaths"

    static func manualFolders(_ defaults: UserDefaults = .standard) -> [URL] {
        (defaults.stringArray(forKey: manualKey) ?? []).map { URL(filePath: $0, directoryHint: .isDirectory) }
    }

    static func addManualFolder(_ folder: URL, _ defaults: UserDefaults = .standard) {
        let paths = defaults.stringArray(forKey: manualKey) ?? []
        let path = folder.standardizedFileURL.path(percentEncoded: false)
        if !paths.contains(path) { defaults.set(paths + [path], forKey: manualKey) }
    }

    static func runnerID(version: String) -> String {
        "gptk-" + String(version.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == ".") ? $0 : "_" })
    }

    static func folder(version: String, runners: URL = SupportPaths.runners) -> URL {
        runners.appending(path: runnerID(version: version))
    }

    static func framework(inLib lib: URL) -> URL {
        lib.appending(path: "external/D3DMetal.framework")
    }

    // The lib folder inside whatever the user points at
    static func lib(in candidate: URL) -> URL? {
        let fm = FileManager.default
        for lib in [candidate, candidate.appending(path: "lib"), candidate.appending(path: "redist/lib"),
                    candidate.appending(path: "Contents/Resources/wine/lib")] {
            if fm.fileExists(atPath: framework(inLib: lib).path(percentEncoded: false)) { return lib.standardizedFileURL }
        }
        return nil
    }

    static func version(ofLib lib: URL) -> String? {
        let framework = framework(inLib: lib)
        for plist in ["Versions/A/Resources/Info.plist", "Resources/Info.plist"] {
            guard let data = try? Data(contentsOf: framework.appending(path: plist)),
                  let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let version = (dict["CFBundleShortVersionString"] ?? dict["CFBundleVersion"]) as? String,
                  !version.isEmpty
            else { continue }
            return version
        }
        return nil
    }

    static func discover(_ search: Search = .standard) -> [PortingToolkitInstall] {
        let fm = FileManager.default
        var candidates = search.manual
        let volumes = (try? fm.contentsOfDirectory(at: search.volumes, includingPropertiesForKeys: nil)) ?? []
        candidates += volumes.sorted { $0.lastPathComponent < $1.lastPathComponent }
        for folder in search.applications {
            let apps = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            candidates += apps.filter {
                $0.pathExtension == "app" && $0.lastPathComponent.localizedCaseInsensitiveContains("Porting Toolkit")
            }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        candidates += search.homebrew

        var found: [PortingToolkitInstall] = []
        var versions: Set<String> = []
        for candidate in candidates {
            guard let lib = lib(in: candidate), let version = version(ofLib: lib) else { continue }
            // The first place a version is found is where it is copied from
            guard versions.insert(version).inserted else { continue }
            found.append(PortingToolkitInstall(lib: lib, version: version, origin: candidate))
        }
        return found
    }

    static func receipt(version: String, runners: URL = SupportPaths.runners) -> Receipt? {
        let file = folder(version: version, runners: runners).appending(path: receiptName)
        return (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Receipt.self, from: $0) }
    }

    static func copiedVersions(in runners: URL = SupportPaths.runners) -> [String] {
        let entries = (try? FileManager.default.contentsOfDirectory(at: runners, includingPropertiesForKeys: nil)) ?? []
        return entries.filter { $0.lastPathComponent.hasPrefix("gptk-") }
            .compactMap { (try? Data(contentsOf: $0.appending(path: receiptName))).flatMap { try? JSONDecoder().decode(Receipt.self, from: $0) } }
            .map(\.version)
            .sorted()
    }

    // Copies the user's lib folder, then moves it in whole, so a half copy is never used
    @discardableResult
    static func copy(_ install: PortingToolkitInstall, runners: URL = SupportPaths.runners) throws -> Receipt {
        let fm = FileManager.default
        let target = folder(version: install.version, runners: runners)
        let staging = runners.appending(path: ".\(target.lastPathComponent).new")
        try? fm.removeItem(at: staging)
        defer { try? fm.removeItem(at: staging) }
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            try fm.copyItem(at: install.lib, to: staging.appending(path: "lib"))
        } catch {
            throw StepFailure(step: step, detail: String(localized: "\(install.origin.path(percentEncoded: false)) could not be copied. ") + error.localizedDescription)
        }
        let receipt = Receipt(
            version: install.version, origin: install.origin.path(percentEncoded: false),
            files: hashes(in: staging))
        try JSONEncoder().encode(receipt).write(to: staging.appending(path: receiptName))
        try? fm.removeItem(at: target)
        try fm.moveItem(at: staging, to: target)
        return receipt
    }

    // Every regular file under lib/, by path relative to the runner folder
    static func hashes(in root: URL) -> [String: String] {
        let lib = root.appending(path: "lib")
        guard let walker = FileManager.default.enumerator(at: lib, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return [:] }
        let base = root.standardizedFileURL.path(percentEncoded: false)
        var files: [String: String] = [:]
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values?.isRegularFile == true, values?.isSymbolicLink != true, let hash = try? Digest.sha256(of: url) else { continue }
            let path = url.standardizedFileURL.path(percentEncoded: false)
            files[String(path.dropFirst(base.count).drop { $0 == "/" })] = hash
        }
        return files
    }

    static func verify(version: String, runners: URL = SupportPaths.runners) -> [String] {
        guard let receipt = receipt(version: version, runners: runners) else { return [] }
        let root = folder(version: version, runners: runners)
        return receipt.files.keys.sorted().compactMap { path in
            Digest.sha256IfPresent(root.appending(path: path)) == receipt.files[path]
                ? nil : String(localized: "\(path) changed since it was installed.")
        }
    }

    // One runner per version copied or found; none at all when the user has no toolkit
    static func runners(found: [PortingToolkitInstall], runners: URL) -> [Runner] {
        var listed: [Runner] = []
        let copied = copiedVersions(in: runners)
        for version in copied {
            let problems = verify(version: version, runners: runners)
            listed.append(Runner(
                id: runnerID(version: version), kind: .portingToolkit, version: version, displayVersion: version,
                flavors: [.rosetta], state: problems.isEmpty ? .ready : .damaged(files: problems), build: nil,
                source: found.first { $0.version == version }?.origin, isInstalled: true
            ))
        }
        for install in found where !copied.contains(install.version) {
            listed.append(Runner(
                id: install.id, kind: .portingToolkit, version: install.version, displayVersion: install.version,
                flavors: [.rosetta], state: .available, build: nil, source: install.origin, isInstalled: false
            ))
        }
        return listed
    }
}

// Where D3DMetal can come from on this Mac. Never from Cartouche itself.
enum D3DMetalProvider: Sendable, Equatable {
    case portingToolkit(version: String, framework: URL)
    case crossOver(framework: URL)
}

extension RunnerRegistry {

    // CrossOver carries its own D3DMetal under lib64/apple_gptk
    static func crossOverD3DMetal(inRoot root: URL) -> URL? {
        let framework = root.appending(path: "lib64/apple_gptk/external/D3DMetal.framework")
        return FileManager.default.fileExists(atPath: framework.path(percentEncoded: false)) ? framework : nil
    }

    // The user's own toolkit first, then a CrossOver that provides it; nil means D3DMetal is not offered
    func d3dMetal(runners folder: URL = SupportPaths.runners) -> D3DMetalProvider? {
        if let toolkit = runners.last(where: { $0.kind == .portingToolkit && $0.state == .ready }) {
            let lib = PortingToolkitSource.folder(version: toolkit.version, runners: folder).appending(path: "lib")
            return .portingToolkit(version: toolkit.version, framework: PortingToolkitSource.framework(inLib: lib))
        }
        let roots = installed.map { SupportPaths.clonedRoot(forBuild: $0.id, runners: folder) }
            + installs.filter(\.isUsable).map(\.crossOverRoot)
        for root in roots {
            if let framework = Self.crossOverD3DMetal(inRoot: root) { return .crossOver(framework: framework) }
        }
        return nil
    }
}
