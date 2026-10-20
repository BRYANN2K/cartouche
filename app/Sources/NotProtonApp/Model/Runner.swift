
import Foundation

struct Runner: Sendable, Equatable, Identifiable {

    enum Kind: String, Sendable, CaseIterable {
        case crossOver
        case wineBuild
        case portingToolkit

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
        indirect case installing(from: State)
        case ready
        case damaged(files: [String])
        case unsupported(reason: String)
    }

    enum Event: Sendable, Equatable {
        case install
        case verified(problems: [String])
        case failed
    }

    let id: String
    let kind: Kind
    let version: String
    let displayVersion: String
    let flavors: [CompatTool.Flavor]
    var state: State
    // Pinned hashes. Nil when the build is not pinned.
    let build: RunnerBuild?
    let source: URL?
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
