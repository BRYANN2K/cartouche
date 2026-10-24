import AppKit
import Foundation
import Testing

@testable import NotProtonApp

@Suite("Permission catalog")
struct PermissionCatalogTests {

    @Test("The catalog is the inventory in design.md, and nothing more")
    func inventory() {
        #expect(Permission.allCases.count == 11)
        #expect(Permission.allCases.filter { $0.holder == .steam } == [.steamInput])
        #expect(Permission.allCases.filter { $0.holder == .games } == [.gameInputMonitoring])
        #expect(Permission.allCases.filter(\.needsRelaunch) == [.inputMonitoring])
        #expect(Permission.notifications.moment == .afterFirstDownloadOrInstall)
        #expect(Permission.keychain.moment == .never)
        #expect(Permission.removableVolumes.moment == .folderAdded)
        #expect(Permission.localNetwork.moment == .firstNetplay)
        for permission in Permission.allCases {
            #expect(!permission.title.isEmpty)
            #expect(!permission.feature.isEmpty)
        }
    }

    // One row per permission: what the live probe can say, and the state shown
    struct Case: Sendable, CustomTestStringConvertible {
        let permission: Permission
        let answer: SystemAnswer
        let asked: Bool
        var last: PermissionState?
        let expected: PermissionState

        var testDescription: String {
            "\(permission.rawValue) \(answer) asked:\(asked) last:\(last?.rawValue ?? "-") → \(expected.rawValue)"
        }
    }

    static let cases: [Case] = [
        // App Management: only a real write tells, so the last attempt decides
        Case(permission: .appManagement, answer: .unreadable, asked: false, expected: .notAsked),
        Case(permission: .appManagement, answer: .unreadable, asked: true, last: .denied, expected: .denied),
        Case(permission: .appManagement, answer: .granted, asked: true, last: .denied, expected: .allowed),
        Case(permission: .appManagement, answer: .denied, asked: true, last: .allowed, expected: .denied),
        // Steam's own grant, which Cartouche cannot read
        Case(permission: .steamInput, answer: .unreadable, asked: false, expected: .unknown),
        // Accessibility: AXIsProcessTrusted says yes or "not granted"
        Case(permission: .accessibility, answer: .granted, asked: false, expected: .allowed),
        Case(permission: .accessibility, answer: .notGranted, asked: false, expected: .notAsked),
        Case(permission: .accessibility, answer: .notGranted, asked: true, expected: .denied),
        Case(permission: .gameInputMonitoring, answer: .unreadable, asked: false, expected: .unknown),
        // Input Monitoring: IOHIDCheckAccess answers all three
        Case(permission: .inputMonitoring, answer: .granted, asked: true, expected: .allowed),
        Case(permission: .inputMonitoring, answer: .denied, asked: true, expected: .denied),
        Case(permission: .inputMonitoring, answer: .undetermined, asked: false, expected: .notAsked),
        // Downloads: reading the folder would prompt, so it waits for the user
        Case(permission: .downloads, answer: .unreadable, asked: false, expected: .notAsked),
        Case(permission: .downloads, answer: .unreadable, asked: true, last: .denied, expected: .denied),
        Case(permission: .downloads, answer: .granted, asked: true, last: .denied, expected: .allowed),
        Case(permission: .removableVolumes, answer: .unreadable, asked: false, expected: .notAsked),
        Case(permission: .removableVolumes, answer: .denied, asked: true, expected: .denied),
        // Local Network: no API at all
        Case(permission: .localNetwork, answer: .unreadable, asked: false, expected: .notAsked),
        Case(permission: .localNetwork, answer: .unreadable, asked: true, expected: .unknown),
        // Notifications: notificationSettings answers all three
        Case(permission: .notifications, answer: .undetermined, asked: false, expected: .notAsked),
        Case(permission: .notifications, answer: .granted, asked: true, expected: .allowed),
        Case(permission: .notifications, answer: .denied, asked: true, expected: .denied),
        // Login Items: SMAppService status
        Case(permission: .loginItems, answer: .undetermined, asked: false, expected: .notAsked),
        Case(permission: .loginItems, answer: .granted, asked: true, expected: .allowed),
        Case(permission: .loginItems, answer: .denied, asked: true, expected: .denied),
        // Keychain: no prompt with a stable signature
        Case(permission: .keychain, answer: .unreadable, asked: false, expected: .allowed),
    ]

    @Test("Each permission's state comes from the mocked TCC answer and what Cartouche remembers", arguments: cases)
    @MainActor
    func stateFromAnswer(_ row: Case) async {
        let scratch = ScratchDefaults()
        if row.asked { scratch.ledger.noteAsked(row.permission) }
        if let last = row.last { scratch.ledger.note(last, for: row.permission) }
        let tcc = FakeTCC([row.permission: row.answer])
        let center = makeCenter(tcc, scratch)

        await center.refresh()

        #expect(center.state(row.permission) == row.expected)
        #expect(tcc.requests.isEmpty, "reading a state asked macOS")
    }

    @Test("Every permission in the catalog is covered by a mocked answer above")
    func everyPermissionCovered() {
        #expect(Set(Self.cases.map(\.permission)) == Set(Permission.allCases))
    }

    @Test("A refresh reads every permission without a deep check or a prompt")
    @MainActor
    func refreshIsShallow() async {
        let scratch = ScratchDefaults()
        scratch.ledger.setRecheck(true, for: .appManagement)
        let tcc = FakeTCC()
        let center = makeCenter(tcc, scratch)

        await center.refresh()

        #expect(Set(tcc.reads) == Set(Permission.allCases))
        #expect(tcc.deepReads.isEmpty)
        #expect(tcc.requests.isEmpty)
    }

    @Test("Coming back to Cartouche checks deeply only what the user went to change, once")
    @MainActor
    func activationRecheck() async {
        let scratch = ScratchDefaults()
        scratch.ledger.note(.denied, for: .appManagement)
        scratch.ledger.setRecheck(true, for: .appManagement)
        let tcc = FakeTCC([.appManagement: .granted])
        let center = makeCenter(tcc, scratch)

        await center.applicationDidBecomeActive()
        #expect(tcc.deepReads == [.appManagement])
        #expect(center.state(.appManagement) == .allowed)
        #expect(scratch.ledger.last(.appManagement) == .allowed)

        await center.applicationDidBecomeActive()
        #expect(tcc.deepReads == [.appManagement], "a second activation checked again")
    }

    @Test("The activation notification triggers the recheck")
    @MainActor
    func activationNotification() async throws {
        let scratch = ScratchDefaults()
        scratch.ledger.note(.denied, for: .downloads)
        scratch.ledger.setRecheck(true, for: .downloads)
        let tcc = FakeTCC([.downloads: .granted])
        let notifications = NotificationCenter()
        let center = PermissionCenter(probe: tcc, requester: tcc, ledger: scratch.ledger,
                                      opener: { _ in true }, notifications: notifications)
        center.watchActivation()

        notifications.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        for _ in 0..<100 where center.state(.downloads) != .allowed {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(center.state(.downloads) == .allowed)
    }

    @Test("The ledger keeps its answers in the defaults domain it is given")
    func ledgerRoundTrip() {
        let scratch = ScratchDefaults()
        let ledger = scratch.ledger
        #expect(!ledger.wasAsked(.downloads))
        ledger.note(.denied, for: .downloads)
        ledger.setTarget(URL(filePath: "/Volumes/Games"), for: .removableVolumes)
        let again = PermissionLedger(defaults: scratch.defaults)
        #expect(again.wasAsked(.downloads))
        #expect(again.last(.downloads) == .denied)
        #expect(again.target(.removableVolumes)?.path(percentEncoded: false) == "/Volumes/Games")
    }
}

// The live probe's file checks, on fixtures. They read plain POSIX permissions,
// which is how a TCC refusal looks to the process too.
@Suite("Permission probe file checks")
struct PermissionProbeFileTests {

    @Test("A write refused inside an app bundle reads as denied, and nothing is left behind")
    func writeRefused() throws {
        let work = try scratchDirectory("probe")
        defer {
            chmod(work.appending(path: "Steam.app/Contents").path(percentEncoded: false), 0o755)
            try? FileManager.default.removeItem(at: work)
        }
        let contents = work.appending(path: "Steam.app/Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try Data().write(to: contents.appending(path: "Info.plist"))

        #expect(LivePermissionProbe.writeCheck(inside: work.appending(path: "Steam.app")) == .granted)
        #expect(!FileManager.default.fileExists(atPath: contents.appending(path: ".cartouche-access-check").path))

        chmod(contents.path(percentEncoded: false), 0o555)
        #expect(LivePermissionProbe.writeCheck(inside: work.appending(path: "Steam.app")) == .denied)
    }

    @Test("A missing app or folder cannot be read, rather than being denied")
    func missing() throws {
        let work = try scratchDirectory("probe")
        defer { try? FileManager.default.removeItem(at: work) }
        #expect(LivePermissionProbe.writeCheck(inside: work.appending(path: "None.app")) == .unreadable)
        #expect(LivePermissionProbe.readCheck(work.appending(path: "none")) == .unreadable)
    }

    @Test("A folder that refuses listing reads as denied")
    func readRefused() throws {
        let work = try scratchDirectory("probe")
        let folder = work.appending(path: "Downloads")
        defer {
            chmod(folder.path(percentEncoded: false), 0o755)
            try? FileManager.default.removeItem(at: work)
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #expect(LivePermissionProbe.readCheck(folder) == .granted)
        chmod(folder.path(percentEncoded: false), 0o000)
        #expect(LivePermissionProbe.readCheck(folder) == .denied)
    }
}
