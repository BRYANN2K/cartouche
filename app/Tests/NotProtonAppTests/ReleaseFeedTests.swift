import Foundation
import Sparkle
import Testing

@testable import NotProtonApp

// The release pipeline (packaging/release.py, the Makefile) and Sparkle must agree
// on how versions order, or an update is never offered.
@Suite("Release feed")
struct ReleaseFeedTests {

    @Test("The app refuses a feed that is not EdDSA-signed")
    func feedMustBeSigned() throws {
        let plist = try IdentityTests.infoPlist()
        #expect(plist["SURequireSignedFeed"] as? Bool == true)
    }

    @Test("Bundle versions of betas sort before their release and after the one before")
    func bundleVersionsOrder() {
        let ordered = ["0.0.1t1", "0.0.1t2", "0.1.0", "0.1.1", "0.2.0b1", "0.2.0b2", "0.2.0b10", "0.2.0", "0.10.0"]
        let comparator = SUStandardVersionComparator.default
        for (older, newer) in zip(ordered, ordered.dropFirst()) {
            #expect(comparator.compareVersion(older, toVersion: newer) == .orderedAscending, "\(older) < \(newer)")
        }
    }

    @Test("A dashed pre-release version would not order, which is why the bundle drops the dash")
    func dashedVersionsDoNotOrder() {
        let comparator = SUStandardVersionComparator.default
        #expect(comparator.compareVersion("0.2.0-beta.1", toVersion: "0.2.0") == .orderedSame)
    }

    @Test("The Makefile turns pre-release versions into the bundle versions Sparkle orders")
    func makefileMapsBundleVersions() throws {
        let makefile = try String(contentsOf: IdentityTests.repoRoot.appending(path: "Makefile"), encoding: .utf8)
        #expect(makefile.contains(#""Set :CFBundleVersion $(APP_BUNDLE_VERSION)""#))
        for (version, bundle) in [("0.1.0", "0.1.0"), ("0.2.0-beta.12", "0.2.0b12"), ("0.0.1-test.3", "0.0.1t3")] {
            let make = Process()
            make.executableURL = URL(filePath: "/usr/bin/make")
            make.currentDirectoryURL = IdentityTests.repoRoot
            make.arguments = ["-s", "-p", "-n", "APP_VERSION=\(version)", "-f", "Makefile", "FORCE"]
            let out = Pipe()
            make.standardOutput = out
            make.standardError = FileHandle.nullDevice
            try make.run()
            let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            make.waitUntilExit()
            #expect(text.contains("APP_BUNDLE_VERSION := \(bundle)\n"), "\(version) -> \(bundle)")
        }
    }
}
