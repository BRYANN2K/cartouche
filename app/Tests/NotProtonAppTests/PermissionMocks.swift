import AppKit
import Foundation
import SwiftUI
import Synchronization

@testable import NotProtonApp

// Stands in for TCC. No test reads or changes the real permission database.
final class FakeTCC: PermissionProbe, PermissionRequester, Sendable {
    struct Calls {
        var answers: [Permission: SystemAnswer] = [:]
        // What macOS answers once the user decided in its prompt
        var decisions: [Permission: SystemAnswer] = [:]
        var requests: [Permission] = []
        var deepReads: [Permission] = []
        var reads: [Permission] = []
    }

    private let calls = Mutex(Calls())
    // Like the live probe, these answer only to a deep check
    let deepOnly: Set<Permission>

    static let fileChecks: Set<Permission> = [.appManagement, .downloads, .removableVolumes]

    init(_ answers: [Permission: SystemAnswer] = [:], deepOnly: Set<Permission> = []) {
        self.deepOnly = deepOnly
        calls.withLock { $0.answers = answers }
    }

    func set(_ permission: Permission, _ answer: SystemAnswer) {
        calls.withLock { $0.answers[permission] = answer }
    }

    func decide(_ permission: Permission, _ answer: SystemAnswer) {
        calls.withLock { $0.decisions[permission] = answer }
    }

    var requests: [Permission] { calls.withLock { $0.requests } }
    var deepReads: [Permission] { calls.withLock { $0.deepReads } }
    var reads: [Permission] { calls.withLock { $0.reads } }

    func answer(for permission: Permission, deep: Bool, target: URL?) async -> SystemAnswer {
        calls.withLock {
            $0.reads.append(permission)
            if deep { $0.deepReads.append(permission) }
            if !deep && deepOnly.contains(permission) { return .unreadable }
            return $0.answers[permission] ?? .unreadable
        }
    }

    func request(_ permission: Permission, target: URL?) async -> SystemAnswer {
        calls.withLock {
            $0.requests.append(permission)
            if let decided = $0.decisions[permission] { $0.answers[permission] = decided }
            return $0.answers[permission] ?? .unreadable
        }
    }
}

// A defaults domain of its own, so tests never see the app's real choices
final class ScratchDefaults {
    let name = "cartouche-tests-\(UUID().uuidString)"
    let defaults: UserDefaults

    init() {
        defaults = UserDefaults(suiteName: name)!
    }

    deinit {
        defaults.removePersistentDomain(forName: name)
    }

    var ledger: PermissionLedger { PermissionLedger(defaults: defaults) }
}

@MainActor
func makeCenter(_ tcc: FakeTCC, _ scratch: ScratchDefaults) -> PermissionCenter {
    // The opener never reaches NSWorkspace, so no test opens System Settings
    PermissionCenter(probe: tcc, requester: tcc, ledger: scratch.ledger,
                     opener: { _ in true }, notifications: NotificationCenter())
}

// Renders a view offscreen, for evidence screenshots. Writes PNGs only when
// CARTOUCHE_SNAPSHOTS names a folder; returns the image size either way.
@MainActor
@discardableResult
func snapshot<V: View>(_ view: V, named name: String, dark: Bool = false) -> CGSize {
    let host = NSHostingView(rootView: view.padding(12).background(Color(nsColor: .windowBackgroundColor)))
    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    let size = host.fittingSize
    host.frame = CGRect(origin: .zero, size: size)
    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = host.appearance
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    if let folder = ProcessInfo.processInfo.environment["CARTOUCHE_SNAPSHOTS"],
       let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
        host.cacheDisplay(in: host.bounds, to: rep)
        let url = URL(filePath: folder).appending(path: "\(name)-\(dark ? "dark" : "light").png")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
    return size
}
