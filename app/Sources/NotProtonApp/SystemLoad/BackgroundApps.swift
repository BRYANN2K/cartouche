import AppKit
import Foundation
import Observation

// When « Apps en arrière-plan » may open by itself: before Play alone, and never once
// muted. The menu, ⌥⌘R and a click on the warning's notification open it by hand.
struct BackgroundAppsRules: Equatable, Sendable {
    var muted = false

    func onPlay(overloaded: Bool) -> Bool { overloaded && !muted }
}

@MainActor
@Observable
final class BackgroundAppsPresenter {
    enum Mode: Equatable, Sendable { case manual, play }

    static let shared = BackgroundAppsPresenter()

    private(set) var mode: Mode?
    var muteChecked = false
    private(set) var rules = BackgroundAppsRules()

    @ObservationIgnored private var pendingPlay: (() -> Void)?
    @ObservationIgnored var showMainWindow: @MainActor () -> Void = {}

    var isOpen: Bool { mode != nil }

    func show(_ mode: Mode = .manual) {
        showMainWindow()
        if self.mode == nil { muteChecked = false }
        self.mode = mode
    }

    // Play launches what Play deferred; Cancel, Escape and a click outside launch nothing
    func close(play: Bool = false) {
        guard let mode else { return }
        if muteChecked && mode == .play { rules.muted = true }
        let go = play ? pendingPlay : nil
        pendingPlay = nil
        muteChecked = false
        self.mode = nil
        go?()
    }

    // Play on an overloaded Mac shows the window first; anything else plays at once
    func beforePlay(overloaded: Bool, _ go: @escaping () -> Void) {
        guard rules.onPlay(overloaded: overloaded), mode == nil else { return go() }
        pendingPlay = go
        show(.play)
    }
}

// Numbers as the window writes them: the digits alone, tabular, the unit in a box of its own.
// Memory is always in GB with one decimal, never in MB.
enum BackgroundAppsFormat {
    static let gigabyte = 1_073_741_824.0

    static func percent(_ value: Double?, locale: Locale = .current) -> String {
        guard let value, value.isFinite else { return "—" }
        return Int(value.rounded()).formatted(.number.grouping(.never).locale(locale))
    }

    static func gigabytes(_ bytes: UInt64?, locale: Locale = .current) -> String {
        guard let bytes else { return "—" }
        return (Double(bytes) / gigabyte).formatted(.number.precision(.fractionLength(1)).grouping(.never).locale(locale))
    }

    // The Mac's RAM as sold: 24, never 23,9
    static func total(_ physical: UInt64) -> Int { Int((Double(physical) / gigabyte).rounded()) }

    static func memory(used: UInt64, physical: UInt64, locale: Locale = .current) -> String {
        "\(gigabytes(used, locale: locale)) / \(total(physical).formatted(.number.grouping(.never).locale(locale)))"
    }
}
