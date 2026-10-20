import Foundation
import Testing

@testable import NotProtonApp

@Suite("App identity")
struct IdentityTests {

    static let repoRoot = URL(filePath: #filePath)
        .deletingLastPathComponent()  // NotProtonAppTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // app
        .deletingLastPathComponent()  // repo root

    static func infoPlist() throws -> [String: Any] {
        let data = try Data(contentsOf: repoRoot.appending(path: "app/Info.plist"))
        return try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    static func appSources() throws -> [URL] {
        let sources = repoRoot.appending(path: "app/Sources/NotProtonApp")
        let walk = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        return walk.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    @Test("The bundle is named Cartouche under its own identifier")
    func bundleIdentity() throws {
        let plist = try Self.infoPlist()
        #expect(plist["CFBundleIdentifier"] as? String == "dev.bryann2k.cartouche")
        #expect(plist["CFBundleName"] as? String == "Cartouche")
        #expect(plist["CFBundleDisplayName"] as? String == "Cartouche")
        #expect(plist["CFBundleExecutable"] as? String == "Cartouche")
    }

    @Test("Updates come from the Cartouche feed, signed with the Cartouche key")
    func updateFeedAndKey() throws {
        let plist = try Self.infoPlist()
        let feedString = try #require(plist["SUFeedURL"] as? String)
        let feed = try #require(URL(string: feedString))
        #expect(feed.scheme == "https")
        #expect(feed.host == "github.com")
        #expect(feed.path.hasPrefix("/BRYANN2K/"))
        #expect(feed.path.hasSuffix("/releases/latest/download/appcast.xml"))
        #expect(!feed.absoluteString.contains("NotProtonNot"))

        let key = try #require(plist["SUPublicEDKey"] as? String)
        #expect(key != "rDOXzJ+vt12aWeu9hATgvz6q46MlRcgR4gbTfj5YuWQ=", "NotProton's public key")
        #expect(Data(base64Encoded: key)?.count == 32)
    }

    @Test("No localized string names NotProton")
    func catalogIsRenamed() throws {
        let catalog = try String(
            contentsOf: Self.repoRoot.appending(path: "app/Sources/NotProtonApp/Resources/Localization/Localizable.xcstrings"),
            encoding: .utf8)
        #expect(!catalog.localizedCaseInsensitiveContains("NotProton"))
    }

    @Test("Only the About attribution names NotProton in app text")
    func onlyAttributionNamesNotProton() throws {
        let literal = try Regex(#""[^"\n]*NotProton[^"\n]*""#)
        var offenders: [String] = []
        for file in try Self.appSources() where file.lastPathComponent != "Attribution.swift" {
            let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
            for (number, line) in lines.enumerated() where line.contains(literal) {
                offenders.append("\(file.lastPathComponent):\(number + 1)")
            }
        }
        #expect(offenders.isEmpty, "NotProton in user-facing text: \(offenders)")
    }

    @Test("The About window links the website, credits NotProton, states the license and the non-affiliation")
    func aboutCredits() {
        let credits = Attribution.credits
        #expect(credits.hasPrefix("https://cartouche.bryann2k.dev\n"))
        #expect(credits.contains("started as a fork of NotProton"))
        #expect(credits.contains("https://github.com/NotProtonNot/NotProton"))
        #expect(credits.contains("GNU General Public License version 3 (GPL-3.0)"))
        #expect(credits.contains(
            "Cartouche is now its own project, not built on NotProton. It is not affiliated with NotProton, Valve, Apple or CodeWeavers."))
    }

    @Test("README, NOTICE and LICENSE carry the attribution")
    func repositoryAttribution() throws {
        for name in ["README.md", "NOTICE"] {
            let text = try String(contentsOf: Self.repoRoot.appending(path: name), encoding: .utf8)
            #expect(text.contains("https://github.com/NotProtonNot/NotProton"), "\(name) credits NotProton")
            #expect(text.contains("GNU General Public License version 3 (GPL-3.0)"), "\(name) states GPL-3.0")
            #expect(text.contains(Attribution.nonAffiliation), "\(name) has the non-affiliation sentence")
        }
        let license = try String(contentsOf: Self.repoRoot.appending(path: "LICENSE"), encoding: .utf8)
        #expect(license.hasPrefix("Cartouche, a fork of NotProton,"))
        #expect(license.contains("GNU GENERAL PUBLIC LICENSE\n                       Version 3, 29 June 2007"))
    }

    // cartouche_identity.h is what the dylib compiles against, so its text is the dylib's side.
    static func headerDefine(_ name: String) throws -> String {
        let header = try String(
            contentsOf: repoRoot.appending(path: "app/Sources/CartoucheIdentity/include/cartouche_identity.h"),
            encoding: .utf8)
        let line = try #require(header.split(separator: "\n").first { $0.hasPrefix("#define \(name) ") })
        var value = ""
        for piece in line.dropFirst("#define \(name) ".count).matches(of: /"([^"]*)"|CARTOUCHE_DIR_NAME/) {
            value += try piece.output.1.map(String.init) ?? headerDefine("CARTOUCHE_DIR_NAME")
        }
        return value
    }

    @Test("The app and the dylib use the same data and log folders")
    func appAndDylibShareTheRoot() throws {
        let home = SupportPaths.home.path(percentEncoded: false)
        #expect(SupportPaths.supportDirName == "Cartouche")
        #expect(try Self.headerDefine("CARTOUCHE_DIR_NAME") == SupportPaths.supportDirName)
        #expect(try "\(home)/\(Self.headerDefine("CARTOUCHE_SUPPORT_DIR"))"
            == SupportPaths.support.path(percentEncoded: false))
        #expect(try "\(home)/\(Self.headerDefine("CARTOUCHE_LOGS_DIR"))"
            == SupportPaths.logs.path(percentEncoded: false))
        #expect(SupportPaths.support.path(percentEncoded: false).hasSuffix("/Library/Application Support/Cartouche"))
        #expect(SupportPaths.logs.path(percentEncoded: false).hasSuffix("/Library/Logs/Cartouche"))
        #expect(AppLog.file.deletingLastPathComponent().path(percentEncoded: false)
            == SupportPaths.logs.path(percentEncoded: false) + "/")

        let file = try String(contentsOf: Self.repoRoot.appending(path: "dylib/util/file.c"), encoding: .utf8)
        #expect(file.contains("#include \"cartouche_identity.h\""))
        #expect(file.contains("CARTOUCHE_SUPPORT_DIR"))
        #expect(file.contains("CARTOUCHE_LOGS_DIR"))
        let log = try String(contentsOf: Self.repoRoot.appending(path: "dylib/util/log.c"), encoding: .utf8)
        #expect(log.contains("np_logs_path(folder"))
    }

    @Test("The run script uses the same data folder")
    func runScriptSharesTheRoot() throws {
        let script = try String(contentsOf: Self.repoRoot.appending(path: "dylib/feats/compat_run.sh"), encoding: .utf8)
        let support = try Self.headerDefine("CARTOUCHE_SUPPORT_DIR")
        #expect(script.contains("\nnp_support=\"$HOME/\(support)\"\n"))

        // The template cache sits in Steam's compatdata, where NotProton keeps its own,
        // and the app removes templates it does not recognize there.
        #expect(SupportPaths.prefixTemplateFolder == "cartouche-template")
        #expect(script.contains("template_cache=\"$(dirname \"$STEAM_COMPAT_DATA_PATH\")/\(SupportPaths.prefixTemplateFolder)\""))
        #expect(script.contains("/.\(SupportPaths.prefixTemplateFolder).lock\""))
        #expect(!script.localizedCaseInsensitiveContains("notproton"))
    }

    // Steam-side names come from cartouche_identity.h; the run script and the Steam UI
    // patches carry copies, checked here.
    @Test("Cartouche's names inside Steam come from the shared header")
    func steamNamesShareTheHeader() throws {
        let steam = try Self.headerDefine("CARTOUCHE_STEAM_PREFIX")
        let tool = try Self.headerDefine("CARTOUCHE_TOOL_PREFIX")
        #expect(steam == "cartouche")
        #expect(tool.hasPrefix(steam) && tool.contains("proton"), "Steam maps Cloud paths only for proton tools")
        #expect(try Self.headerDefine("CARTOUCHE_DYLIB_NAME") == SupportPaths.dylibName)
        #expect(SupportPaths.dylibName == "cartouche.dylib")
        #expect(SupportPaths.toolPrefix == tool && SupportPaths.steamPrefix == steam)
        for runnerTool in SupportedRunners.all.flatMap(\.tools) {
            #expect(runnerTool.name.hasPrefix(tool))
        }
        #expect(SupportPaths.prefixTemplateFolder == "\(steam)-template")

        let script = try String(contentsOf: Self.repoRoot.appending(path: "dylib/feats/compat_run.sh"), encoding: .utf8)
        #expect(script.hasPrefix("#!/bin/sh\n# \(steam) CrossOver compatibility tool shim\n"))
        for file in ["run.log", "build", "msync", "game-drive", "hidden-controllers", "disable-hidraw"] {
            #expect(script.contains("$STEAM_COMPAT_DATA_PATH/\(steam)-\(file)"), "prefix file \(file)")
        }
        for variable in ["RAW_CONTROLLERS", "DISABLE_HIDRAW", "RETINA", "HIDE_LAUNCHER_TILE", "OVERLAY_SHIM"] {
            #expect(script.contains("CARTOUCHE_\(variable)"), "launch option \(variable)")
        }
        let webpatch = try String(contentsOf: Self.repoRoot.appending(path: "dylib/feats/webpatch.c"), encoding: .utf8)
        #expect(webpatch.contains("\\\"\(steam)Windows\\\""), "library filter key")
    }

    // Only the shared header names NotProton's Steam-side files, so it can detect them.
    @Test("No code uses NotProton's names inside Steam")
    func noNotProtonSteamNames() throws {
        let extensions: Set<String> = ["c", "h", "m", "sh", "py", "swift", "js", "cpp"]
        var files = [Self.repoRoot.appending(path: "Makefile")]
        for directory in ["dylib", "helpers", "bridge", "ntdll-patch", "steam-shim", "overlay-shim", "fps-counter", "lsteamclient",
                          "app/Sources", "tools"] {
            let walk = try #require(FileManager.default.enumerator(
                at: Self.repoRoot.appending(path: directory), includingPropertiesForKeys: nil))
            files += walk.compactMap { $0 as? URL }.filter { extensions.contains($0.pathExtension) }
        }
        let allowed: Set<String> = ["cartouche_identity.h", "Attribution.swift"]
        let name = try Regex("(?i)notproton(?!App)")
        var offenders: [String] = []
        for file in files where !allowed.contains(file.lastPathComponent) {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            if text.contains(name) { offenders.append(file.lastPathComponent) }
        }
        #expect(offenders.isEmpty, "NotProton names in \(offenders)")
        #expect(try Self.headerDefine("CARTOUCHE_OTHER_DYLIB_NAME") == SteamBundle.otherDylibName)
    }

    // Shell and build scripts cannot include the header, so every folder they name under
    // Application Support is checked here: Steam's, CrossOver's or Cartouche's, nothing else.
    @Test("No source or script names another app's data folder")
    func scriptsShareTheRoot() throws {
        let name = try Self.headerDefine("CARTOUCHE_DIR_NAME")
        let allowed: Set<String> = ["Steam", "CrossOver", name]
        let folder = try Regex(#"Application Support/([A-Za-z0-9._-]+)"#)
        let extensions: Set<String> = ["c", "h", "m", "sh", "py", "swift", "js"]
        var files = [Self.repoRoot.appending(path: "Makefile")]
        for directory in ["dylib", "helpers", "bridge", "ntdll-patch", "steam-shim", "overlay-shim", "fps-counter", "lsteamclient",
                          "app/Sources"] {
            let walk = try #require(FileManager.default.enumerator(
                at: Self.repoRoot.appending(path: directory), includingPropertiesForKeys: nil))
            files += walk.compactMap { $0 as? URL }.filter { extensions.contains($0.pathExtension) }
        }
        var offenders: [String] = []
        for file in files {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for match in text.matches(of: folder) {
                let found = String(match.output[1].substring ?? "")
                // gogdl and comet keep their token under "heroic" inside the private HOME
                // Cartouche gives them (StoreRecords.home), never the user's own folder
                if found == "heroic", file.lastPathComponent == "GOGAdapter.swift" { continue }
                if !allowed.contains(found) { offenders.append("\(file.lastPathComponent): \(found)") }
            }
        }
        #expect(files.count > 100)
        #expect(offenders.isEmpty, "unexpected data folders: \(offenders)")
    }
}
