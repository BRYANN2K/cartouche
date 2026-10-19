import CryptoKit
import Foundation
import Testing

@testable import NotProtonApp

// NotProton injects the same Steam under its own names. Every path here is a fixture,
// so nothing touches this Mac's Steam.
@Suite("Coexistence with NotProton")
struct CoexistenceTests {

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var raised = false
        func set() { lock.withLock { raised = true } }
        var value: Bool { lock.withLock { raised } }
    }

    private struct Fixture {
        let root: URL
        let app: URL
        let innerPlist: URL
        let updateBlock: URL
        let legacyCompat: URL
        let tools: URL
        let library: SteamLibrary
        let support: URL

        var outerPlist: URL { app.appending(path: "Contents/Info.plist") }
        var macOS: URL { app.appending(path: "Contents/MacOS") }
        var notProtonDylib: URL { macOS.appending(path: SteamBundle.otherDylibName) }
        var ownDylib: URL { macOS.appending(path: SupportPaths.dylibName) }
        var ownTool: URL { tools.appending(path: "\(SupportPaths.toolPrefix)-26.3") }
        var prefix: URL { library.compatdata.appending(path: "1574480") }
        var modifications: SteamModifications {
            SteamModifications(file: root.appending(path: "steam-bundles.json"),
                               legacyRecord: support.appending(path: "install-build.json"))
        }

        // NotProton's dylib and tools, the files it keeps in a game prefix, and the shared
        // Steam parts it relies on
        var notProtonFiles: [URL] {
            [notProtonDylib, tools.appending(path: "notproton"), tools.appending(path: "notproton-fex"),
             prefix.appending(path: "notproton-run.log"), prefix.appending(path: "notproton-build"),
             library.compatdata.appending(path: "notproton-template"), legacyCompat, updateBlock]
        }
    }

    private func compile(_ output: URL, dylib: Bool, in root: URL) throws {
        let source = root.appending(path: "main.c")
        try Data("int main(void) { return 0; }\n".utf8).write(to: source)
        try Shell.check("/usr/bin/clang", (dylib ? ["-dynamiclib"] : [])
            + ["-o", output.path(percentEncoded: false), source.path(percentEncoded: false)])
    }

    // A Steam that NotProton has installed into, plus Cartouche's own tool and folder.
    // `cartoucheToo` also leaves Cartouche's dylib in the bundle.
    private func fixture(cartoucheToo: Bool = false) throws -> Fixture {
        let files = FileManager.default
        let root = URL.temporaryDirectory.appending(path: "np-coexist-\(UUID().uuidString)")
        let library = SteamLibrary(root: root.appending(path: "library"))
        let fixture = Fixture(
            root: root, app: root.appending(path: "Steam.app"),
            innerPlist: root.appending(path: "inner/Info.plist"),
            updateBlock: root.appending(path: "steam.cfg"),
            legacyCompat: root.appending(path: "inner/legacycompat"),
            tools: root.appending(path: "compatibilitytools.d"),
            library: library, support: root.appending(path: "Cartouche"))

        for dir in [fixture.macOS, fixture.legacyCompat, fixture.ownTool, fixture.support, fixture.prefix,
                    fixture.tools.appending(path: "notproton"), fixture.tools.appending(path: "notproton-fex"),
                    library.compatdata.appending(path: "notproton-template/crossover-1-x86_64")] {
            try files.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try Data("BootStrapperInhibitAll=enable\n".utf8).write(to: fixture.updateBlock)
        try Data("valve".utf8).write(to: fixture.legacyCompat.appending(path: "Steam.dll"))
        for tool in ["notproton", "notproton-fex"] {
            try Data("#!/bin/sh\n# notproton CrossOver compatibility tool shim\n".utf8)
                .write(to: fixture.tools.appending(path: "\(tool)/run"))
        }
        try Data("#!/bin/sh\n".utf8).write(to: fixture.ownTool.appending(path: "run"))
        try Data("log\n".utf8).write(to: fixture.prefix.appending(path: "notproton-run.log"))
        try Data("27.0.0.40921\nCrossOver\n".utf8).write(to: fixture.prefix.appending(path: "notproton-build"))
        try Data("1\n".utf8).write(to: fixture.support.appending(path: "dylib.version"))

        try compile(fixture.macOS.appending(path: "steam_osx"), dylib: false, in: root)
        try compile(fixture.notProtonDylib, dylib: true, in: root)
        if cartoucheToo { try compile(fixture.ownDylib, dylib: true, in: root) }

        let insert = ([fixture.notProtonDylib] + (cartoucheToo ? [fixture.ownDylib] : []))
            .map { $0.path(percentEncoded: false) }.joined(separator: ":")
        let plist: [String: Any] = [
            "CFBundleExecutable": "steam_osx",
            "CFBundleIdentifier": "com.valvesoftware.steam",
            SteamBundle.environmentKey: [
                "LC_ALL": "C",
                SteamBundle.insertKey: insert,
                SteamBundle.controllerBlockKey: SteamBundle.controllerBlockValue,
            ],
        ]
        try files.createDirectory(at: fixture.innerPlist.deletingLastPathComponent(), withIntermediateDirectories: true)
        try SteamBundle.writeInfoPlist(plist, at: fixture.outerPlist)
        try SteamBundle.writeInfoPlist(plist, at: fixture.innerPlist)
        try SteamInstaller.adHocSign(fixture.notProtonDylib)
        try SteamInstaller.adHocSign(fixture.app)
        return fixture
    }

    // Path and content hash of every file under each URL
    private func digest(_ urls: [URL]) throws -> [String: String] {
        var result: [String: String] = [:]
        let files = FileManager.default
        for url in urls {
            var isDirectory: ObjCBool = false
            guard files.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory) else {
                result[url.path(percentEncoded: false)] = "missing"
                continue
            }
            let members = isDirectory.boolValue
                ? (files.subpaths(atPath: url.path(percentEncoded: false)) ?? []).map { url.appending(path: $0) }
                : [url]
            result[url.path(percentEncoded: false)] = "present"
            for member in members {
                var memberIsDirectory: ObjCBool = false
                files.fileExists(atPath: member.path(percentEncoded: false), isDirectory: &memberIsDirectory)
                let hash = memberIsDirectory.boolValue
                    ? "directory"
                    : SHA256.hash(data: try Data(contentsOf: member)).map { String(format: "%02x", $0) }.joined()
                result[member.path(percentEncoded: false)] = hash
            }
        }
        return result
    }

    private func environment(_ plist: URL) -> [String: Any] {
        SteamBundle.readInfoPlist(at: plist)?[SteamBundle.environmentKey] as? [String: Any] ?? [:]
    }

    @Test("NotProton's insert and its dylib are recognized as another tool's")
    func detectsNotProton() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        #expect(SteamBundle.otherInjection(in: fixture.app) == [fixture.notProtonDylib.path(percentEncoded: false)])
        #expect(SteamBundle.foreignInserts(at: fixture.innerPlist) == [fixture.notProtonDylib.path(percentEncoded: false)])
        #expect(SupportPaths.Steam.cartoucheTools(in: fixture.tools).map(\.lastPathComponent) == [fixture.ownTool.lastPathComponent])

        // The dylib alone still counts, so a repair never deletes it
        var plist = try #require(SteamBundle.readInfoPlist(at: fixture.outerPlist))
        plist[SteamBundle.environmentKey] = ["LC_ALL": "C"]
        try SteamBundle.writeInfoPlist(plist, at: fixture.outerPlist)
        #expect(SteamBundle.otherInjection(in: fixture.app) == [fixture.notProtonDylib.path(percentEncoded: false)])
    }

    @Test("Remove Everything leaves NotProton's dylib, tools and prefix files byte-identical")
    func removeEverythingLeavesNotProton() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let before = try digest(fixture.notProtonFiles)
        let outerBefore = environment(fixture.outerPlist) as NSDictionary
        let innerBefore = environment(fixture.innerPlist) as NSDictionary
        let repaired = Flag()

        let outcome = try await Uninstall.run(
            app: fixture.app, innerPlist: fixture.innerPlist, updateBlocks: [fixture.updateBlock],
            legacyCompat: fixture.legacyCompat, compatTools: SupportPaths.Steam.cartoucheTools(in: fixture.tools),
            support: fixture.support, directories: [], libraries: [fixture.library],
            modifications: fixture.modifications, lockFolder: fixture.root,
            repair: { _, _ in repaired.set() }, stop: { _, _ in false })

        #expect(try digest(fixture.notProtonFiles) == before)
        #expect(environment(fixture.outerPlist) as NSDictionary == outerBefore)
        #expect(environment(fixture.innerPlist) as NSDictionary == innerBefore)
        #expect(!repaired.value, "restoring Valve's Steam would delete NotProton's dylib")
        #expect(outcome.leftSteamForOtherTool)
        #expect(!outcome.steamNeedsRedownload)

        let files = FileManager.default
        #expect(!files.fileExists(atPath: fixture.ownTool.path(percentEncoded: false)))
        #expect(!files.fileExists(atPath: fixture.support.path(percentEncoded: false)))
    }

    @Test("Remove Everything takes Cartouche's dylib out of a Steam NotProton also injects")
    func removeEverythingTakesOnlyCartouche() async throws {
        let fixture = try fixture(cartoucheToo: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let before = try digest(fixture.notProtonFiles)
        try fixture.modifications.mark(fixture.app)

        let outcome = try await Uninstall.run(
            app: fixture.app, innerPlist: fixture.innerPlist, updateBlocks: [fixture.updateBlock],
            legacyCompat: fixture.legacyCompat, compatTools: SupportPaths.Steam.cartoucheTools(in: fixture.tools),
            support: fixture.support, directories: [], libraries: [fixture.library],
            modifications: fixture.modifications, lockFolder: fixture.root,
            repair: { _, _ in Issue.record("Steam was restored over NotProton") }, stop: { _, _ in false })

        let notProton = fixture.notProtonDylib.path(percentEncoded: false)
        #expect(try digest(fixture.notProtonFiles) == before)
        #expect(!FileManager.default.fileExists(atPath: fixture.ownDylib.path(percentEncoded: false)))
        #expect(environment(fixture.outerPlist)[SteamBundle.insertKey] as? String == notProton)
        #expect(environment(fixture.innerPlist)[SteamBundle.insertKey] as? String == notProton)
        #expect(environment(fixture.outerPlist)[SteamBundle.controllerBlockKey] as? String == SteamBundle.controllerBlockValue)
        #expect(outcome.detached && outcome.leftSteamForOtherTool)
        #expect(try fixture.modifications.paths().isEmpty)
        let signature = try Shell.run("/usr/bin/codesign", ["--verify", "--strict", fixture.app.path(percentEncoded: false)])
        #expect(signature.succeeded, "Steam still starts after Cartouche's dylib leaves")
    }

    @Test("Repair Steam refuses a Steam that NotProton injects, before changing anything")
    func repairRefusesNotProton() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let before = try digest([fixture.app, fixture.innerPlist, fixture.updateBlock])
        let stopped = Flag()

        do {
            _ = try await SteamRepair.run(
                app: fixture.app, innerPlist: fixture.innerPlist, updateBlocks: [fixture.updateBlock],
                backups: fixture.support.appending(path: "backups"),
                downloads: fixture.root.appending(path: "downloads"), modifications: fixture.modifications,
                stopClient: { _, _ in stopped.set(); return false }, register: { _ in })
            Issue.record("Repair Steam replaced a Steam that NotProton injects")
        } catch let failure as StepFailure {
            #expect(failure.detail.contains("another tool's dylib (\(fixture.notProtonDylib.path(percentEncoded: false)))"))
        }
        #expect(!stopped.value)
        #expect(try digest([fixture.app, fixture.innerPlist, fixture.updateBlock]) == before)
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appending(path: "downloads").path(percentEncoded: false)))
    }

    @Test("Clearing the insert keeps another tool's entry and the controller key it set")
    func clearInsertKeepsOtherEntries() throws {
        let fixture = try fixture(cartoucheToo: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        #expect(try SteamRepair.clearInsert(at: fixture.innerPlist))
        let after = environment(fixture.innerPlist)
        #expect(after[SteamBundle.insertKey] as? String == fixture.notProtonDylib.path(percentEncoded: false))
        #expect(after[SteamBundle.controllerBlockKey] as? String == SteamBundle.controllerBlockValue)
        #expect(after["LC_ALL"] as? String == "C")
        #expect(try SteamRepair.clearInsert(at: fixture.innerPlist) == false, "NotProton's entry is not Cartouche's to clear")
    }
}
