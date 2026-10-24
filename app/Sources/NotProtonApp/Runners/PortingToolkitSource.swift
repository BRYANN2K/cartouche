// Cartouche never ships or downloads toolkit files: Apple's license does not allow redistribution.

import Foundation

struct PortingToolkitInstall: Sendable, Equatable, Identifiable {
    // The folder holding external/D3DMetal.framework (redist/lib on Apple's image)
    let lib: URL
    // D3DMetal.framework's CFBundleShortVersionString, for example 4.0b3
    let version: String
    let origin: URL
    // The origin is a mounted image, which goes away on eject: Copy is the only safe answer
    var mountedImage = false

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
        // Size and mtime pin a copied file without hashing it; receipts before this field carried only the hash and still verify by hashing
        struct File: Sendable, Equatable, Codable {
            let sha256: String
            let size: Int64
            let mtime: Double

            init(sha256: String, size: Int64, mtime: Double) {
                self.sha256 = sha256
                self.size = size
                self.mtime = mtime
            }

            init(from decoder: Decoder) throws {
                if let single = try? decoder.singleValueContainer(),
                   let hash = try? single.decode(String.self) {
                    self.init(sha256: hash, size: -1, mtime: -1)
                    return
                }
                let keyed = try decoder.container(keyedBy: CodingKeys.self)
                self.init(
                    sha256: try keyed.decode(String.self, forKey: .sha256),
                    size: try keyed.decode(Int64.self, forKey: .size),
                    mtime: try keyed.decode(Double.self, forKey: .mtime))
            }
        }

        let version: String
        let origin: String
        let files: [String: File]
        var inPlace: String? = nil
    }

    static let receiptName = ".cartouche-runner.json"
    private static let manualKey = "manualPortingToolkitPaths"
    private static let askedKey = "portingToolkitAsked"

    static func manualFolders(_ defaults: UserDefaults = .standard) -> [URL] {
        (defaults.stringArray(forKey: manualKey) ?? []).map { URL(filePath: $0, directoryHint: .isDirectory) }
    }

    static func addManualFolder(_ folder: URL, _ defaults: UserDefaults = .standard) {
        let paths = defaults.stringArray(forKey: manualKey) ?? []
        let path = folder.standardizedFileURL.path(percentEncoded: false)
        if !paths.contains(path) { defaults.set(paths + [path], forKey: manualKey) }
    }

    static func isAsked(version: String, _ defaults: UserDefaults = .standard) -> Bool {
        (defaults.stringArray(forKey: askedKey) ?? []).contains(version)
    }

    static func markAsked(version: String, _ defaults: UserDefaults = .standard) {
        let versions = defaults.stringArray(forKey: askedKey) ?? []
        if !versions.contains(version) { defaults.set(versions + [version], forKey: askedKey) }
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

        var volumesPath = search.volumes.resolvingSymlinksInPath().path(percentEncoded: false)
        while volumesPath.hasSuffix("/") { volumesPath.removeLast() }
        var found: [PortingToolkitInstall] = []
        var versions: Set<String> = []
        for candidate in candidates {
            guard let lib = lib(in: candidate), let version = version(ofLib: lib) else { continue }
            guard versions.insert(version).inserted else { continue }
            var path = candidate.resolvingSymlinksInPath().path(percentEncoded: false)
            while path.hasSuffix("/") { path.removeLast() }
            found.append(PortingToolkitInstall(
                lib: lib, version: version, origin: candidate,
                mountedImage: path.hasPrefix(volumesPath + "/")))
        }
        return found
    }

    static func receipt(version: String, runners: URL = SupportPaths.runners) -> Receipt? {
        let file = folder(version: version, runners: runners).appending(path: receiptName)
        return JSONFile.load(Receipt.self, from: file)
    }

    static func copiedVersions(in runners: URL = SupportPaths.runners) -> [String] {
        let entries = (try? FileManager.default.contentsOfDirectory(at: runners, includingPropertiesForKeys: nil)) ?? []
        return entries.filter { $0.lastPathComponent.hasPrefix("gptk-") }
            .compactMap { (try? Data(contentsOf: $0.appending(path: receiptName))).flatMap { try? JSONDecoder().decode(Receipt.self, from: $0) } }
            .map(\.version)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    static let graphicsDLLs = ["d3d10", "d3d11", "d3d12", "d3d12core", "dxgi", "nvapi64", "nvngx-on-metalfx"]

    static func graphicsPath(inLib lib: URL) -> String? {
        let pe = lib.appending(path: "wine/x86_64-windows")
        guard ["d3d11", "d3d12", "dxgi"].allSatisfy({
            FileManager.default.fileExists(atPath: pe.appending(path: "\($0).dll").path(percentEncoded: false))
        }) else { return nil }
        return [pe, lib.appending(path: "wine/x86_64-unix")].map { $0.path(percentEncoded: false) }.joined(separator: ":")
    }

    @discardableResult
    static func copy(_ install: PortingToolkitInstall, runners: URL = SupportPaths.runners) throws -> Receipt {
        let fm = FileManager.default
        let target = folder(version: install.version, runners: runners)
        let staging = runners.appending(path: ".\(target.lastPathComponent).new")
        try? fm.removeItem(at: staging)
        defer { try? fm.removeItem(at: staging) }
        do {
            try fm.createDirectory(at: staging.appending(path: "lib"), withIntermediateDirectories: true)
            try fm.copyItem(at: install.lib.appending(path: "external"), to: staging.appending(path: "lib/external"))
            for name in Self.graphicsDLLs {
                let source = install.lib.appending(path: "wine/x86_64-windows/\(name).dll")
                guard fm.fileExists(atPath: source.path(percentEncoded: false)) else { continue }
                let pe = staging.appending(path: "lib/wine/x86_64-windows")
                let unix = staging.appending(path: "lib/wine/x86_64-unix")
                try fm.createDirectory(at: pe, withIntermediateDirectories: true)
                try fm.createDirectory(at: unix, withIntermediateDirectories: true)
                try fm.copyItem(at: source, to: pe.appending(path: "\(name).dll"))
                try fm.createSymbolicLink(atPath: unix.appending(path: "\(name).so").path(percentEncoded: false),
                                          withDestinationPath: "../../external/libd3dshared.dylib")
            }
        } catch {
            throw StepFailure(step: step, detail: String(localized: "\(install.origin.path(percentEncoded: false)) could not be copied. ") + error.localizedDescription)
        }
        let receipt = Receipt(
            version: install.version, origin: install.origin.path(percentEncoded: false),
            files: pins(in: staging))
        try JSONEncoder().encode(receipt).write(to: staging.appending(path: receiptName))
        try swapIn(staging, at: target)
        return receipt
    }

    static func remove(version: String, runners: URL = SupportPaths.runners) throws {
        let target = folder(version: version, runners: runners)
        guard FileManager.default.fileExists(atPath: target.path(percentEncoded: false)) else { return }
        try WriteRefused.catching(target.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: target)
        }
    }

    @discardableResult
    static func useInPlace(_ install: PortingToolkitInstall, runners: URL = SupportPaths.runners) throws -> Receipt {
        let fm = FileManager.default
        let target = folder(version: install.version, runners: runners)
        let staging = runners.appending(path: ".\(target.lastPathComponent).new")
        try? fm.removeItem(at: staging)
        defer { try? fm.removeItem(at: staging) }
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        var inPlace = install.lib.standardizedFileURL.path(percentEncoded: false)
        while inPlace.count > 1 && inPlace.hasSuffix("/") { inPlace.removeLast() }
        let receipt = Receipt(
            version: install.version, origin: install.origin.path(percentEncoded: false),
            files: [:], inPlace: inPlace)
        try JSONEncoder().encode(receipt).write(to: staging.appending(path: receiptName))
        try swapIn(staging, at: target)
        return receipt
    }

    static func libFolder(version: String, runners: URL = SupportPaths.runners) -> URL {
        if let path = receipt(version: version, runners: runners)?.inPlace {
            return URL(filePath: path, directoryHint: .isDirectory)
        }
        return folder(version: version, runners: runners).appending(path: "lib")
    }

    static func libd3dshared(runners: URL = SupportPaths.runners) -> URL? {
        for version in copiedVersions(in: runners).reversed() {
            let shared = libFolder(version: version, runners: runners)
                .appending(path: "external/libd3dshared.dylib")
            if FileManager.default.fileExists(atPath: shared.path(percentEncoded: false)),
               graphicsPath(inLib: shared.deletingLastPathComponent().deletingLastPathComponent()) != nil { return shared }
        }
        return nil
    }

    static func copySize(of lib: URL) -> Int64 {
        guard let walker = FileManager.default.enumerator(
            at: lib, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
        else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }
        return total
    }

    static func pins(in root: URL) -> [String: Receipt.File] {
        let lib = root.appending(path: "lib")
        guard let walker = FileManager.default.enumerator(
            at: lib,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
        else { return [:] }
        let base = root.standardizedFileURL.path(percentEncoded: false)
        var files: [String: Receipt.File] = [:]
        for case let url as URL in walker {
            let values = try? url.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
            guard values?.isRegularFile == true, values?.isSymbolicLink != true,
                  let hash = try? Digest.sha256(of: url) else { continue }
            let path = url.standardizedFileURL.path(percentEncoded: false)
            files[String(path.dropFirst(base.count).drop { $0 == "/" })] = Receipt.File(
                sha256: hash,
                size: Int64(values?.fileSize ?? -1),
                mtime: values?.contentModificationDate?.timeIntervalSince1970 ?? -1)
        }
        return files
    }

    // Size+stamp match counts as intact; deep or old receipts without stamps hash.
    static func verify(version: String, runners: URL = SupportPaths.runners, deep: Bool = false) -> [String] {
        guard let receipt = receipt(version: version, runners: runners) else { return [] }
        // A folder used in place is not hashed — Apple's own updates may change it — but it must be there
        if let inPlace = receipt.inPlace {
            let lib = URL(filePath: inPlace, directoryHint: .isDirectory)
            return FileManager.default.fileExists(atPath: framework(inLib: lib).path(percentEncoded: false))
                ? [] : [String(localized: "The folder at \(inPlace) is gone.")]
        }
        let root = folder(version: version, runners: runners)
        return receipt.files.keys.sorted().compactMap { path in
            let pin = receipt.files[path]!
            let file = root.appending(path: path)
            let damaged = String(localized: "\(path) changed since it was installed.")
            if !deep, pin.size >= 0 {
                let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
                // setattr quantizes stamps to microseconds on some filesystems
                let stamp = values?.contentModificationDate?.timeIntervalSince1970 ?? -1
                let intact = values?.isRegularFile == true
                    && Int64(values?.fileSize ?? -1) == pin.size
                    && abs(stamp - pin.mtime) < 0.000_01
                return intact ? nil : damaged
            }
            return Digest.sha256IfPresent(file) == pin.sha256 ? nil : damaged
        }
    }

    static func runners(found: [PortingToolkitInstall], runners: URL) -> [Runner] {
        var listed: [Runner] = []
        let copied = copiedVersions(in: runners)
        for version in copied {
            let problems = verify(version: version, runners: runners)
            // Use in Place points at its recorded folder, even after it is gone.
            let source = receipt(version: version, runners: runners)?.inPlace
                .map { URL(filePath: $0, directoryHint: .isDirectory) }
                ?? found.first { $0.version == version }?.origin
            listed.append(Runner(
                id: runnerID(version: version), kind: .portingToolkit, version: version, displayVersion: version,
                flavors: [.rosetta], state: problems.isEmpty ? .ready : .damaged(files: problems), build: nil,
                source: source, isInstalled: true
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

extension RunnerRegistry {

    // CrossOver carries its own D3DMetal under lib64/apple_gptk
    static func crossOverD3DMetal(inRoot root: URL) -> URL? {
        let framework = root.appending(path: "lib64/apple_gptk/external/D3DMetal.framework")
        return FileManager.default.fileExists(atPath: framework.path(percentEncoded: false)) ? framework : nil
    }
}
