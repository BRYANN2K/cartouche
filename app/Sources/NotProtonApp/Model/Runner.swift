// One runner the app can set up, whatever its source

import Foundation

struct Runner: Sendable, Equatable, Identifiable {

    enum Kind: String, Sendable, CaseIterable {
        case crossOver
        case wineBuild
        case portingToolkit

        // Product names, so not translated.
        var name: String {
            switch self {
            case .crossOver: "CrossOver"
            case .wineBuild: "Wine"
            case .portingToolkit: "Game Porting Toolkit"
            }
        }
    }

    enum State: Sendable, Equatable {
        case available
        // Being copied or patched. Keeps the state to fall back to if that fails.
        indirect case installing(from: State)
        case ready
        // Each entry names a file that no longer matches its pin.
        case damaged(files: [String])
        // Never offered to Steam or to games.
        case unsupported(reason: String)
    }

    enum Event: Sendable, Equatable {
        case install
        // Verification after an install or on refresh. Empty means every pin matched.
        case verified(problems: [String])
        case failed
    }

    let id: String
    let kind: Kind
    // The build's own version (CFBundleVersion for CrossOver), or what the copy reports
    // when it is not a pinned build.
    let version: String
    let displayVersion: String
    // CPU flavors this runner serves on this Mac.
    let flavors: [CompatTool.Flavor]
    var state: State
    // Pinned hashes. Nil when the build is not pinned.
    let build: RunnerBuild?
    // The copy it is set up from, when one was found on disk.
    let source: URL?
    // True when a complete copy sits under runners/, which is what Steam's tool list
    // is built from.
    let isInstalled: Bool

    var reason: String? {
        switch state {
        case .damaged(let files): files.joined(separator: "\n")
        case .unsupported(let reason): reason
        case .available, .installing, .ready: nil
        }
    }

    var isOffered: Bool {
        guard build != nil, isInstalled else { return false }
        if case .unsupported = state { return false }
        return true
    }

    static func flavors(of build: RunnerBuild, fexAvailable: Bool = CompatTool.Flavor.fexAvailable) -> [CompatTool.Flavor] {
        let served = Set(build.tools.map(\.flavor))
        return CompatTool.Flavor.allCases.filter { served.contains($0) && ($0 != .fex || fexAvailable) }
    }
}

extension Runner.State {

    var canInstall: Bool { applying(.install) != nil }

    // Nil when the event does not apply, for example installing an unsupported build.
    func applying(_ event: Runner.Event) -> Runner.State? {
        switch (self, event) {
        case (.unsupported, _):
            return nil
        case (.installing, .install):
            return nil
        case (.installing, .verified(let problems)):
            return problems.isEmpty ? .ready : .damaged(files: problems)
        case (.installing(let previous), .failed):
            return previous
        case (_, .install):
            return .installing(from: self)
        case (.ready, .verified(let problems)), (.damaged, .verified(let problems)):
            return problems.isEmpty ? .ready : .damaged(files: problems)
        case (.available, .verified), (_, .failed):
            return nil
        }
    }
}

extension Runner {

    @discardableResult
    mutating func apply(_ event: Event) -> Bool {
        guard let next = state.applying(event) else { return false }
        state = next
        return true
    }
}
