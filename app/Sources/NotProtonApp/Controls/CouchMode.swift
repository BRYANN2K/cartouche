import CoreGraphics
import Foundation
import Observation

enum CouchCommand: Equatable, Sendable {
    case move(Direction)
    case previousList, nextList
    case accept, back

    enum Direction: Sendable { case up, down, left, right }
}

struct CouchInput: Sendable {
    var initialDelay: Double = 0.4
    var repeatInterval: Double = 0.12
    static let stickThreshold = 0.6

    private var held: Set<PadButton> = []
    private var nextRepeat: [PadButton: Double] = [:]

    init(initialDelay: Double = 0.4, repeatInterval: Double = 0.12) {
        self.initialDelay = initialDelay
        self.repeatInterval = repeatInterval
    }

    static func buttons(_ state: PadState) -> Set<PadButton> {
        var out = state.pressed
        let stick = state.leftStick
        if stick.y > stickThreshold { out.insert(.up) }
        if stick.y < -stickThreshold { out.insert(.down) }
        if stick.x < -stickThreshold { out.insert(.left) }
        if stick.x > stickThreshold { out.insert(.right) }
        return out
    }

    static func command(_ button: PadButton) -> CouchCommand? {
        switch button {
        case .up: .move(.up)
        case .down: .move(.down)
        case .left: .move(.left)
        case .right: .move(.right)
        case .south: .accept
        case .east: .back
        case .leftShoulder: .previousList
        case .rightShoulder: .nextList
        default: nil
        }
    }

    static let repeating: Set<PadButton> = [.up, .down, .left, .right]

    mutating func commands(_ state: PadState, at time: Double) -> [CouchCommand] {
        let now = Self.buttons(state)
        var out: [CouchCommand] = []
        for button in PadButton.allCases where now.contains(button) {
            guard let command = Self.command(button) else { continue }
            if !held.contains(button) {
                out.append(command)
                nextRepeat[button] = time + initialDelay
            } else if Self.repeating.contains(button), let due = nextRepeat[button], time >= due {
                out.append(command)
                nextRepeat[button] = time + repeatInterval
            }
        }
        for button in held.subtracting(now) { nextRepeat[button] = nil }
        held = now
        return out
    }

    mutating func reset() {
        held = []
        nextRepeat = [:]
    }
}

@MainActor
@Observable
final class CouchNavigator {

    enum Focus: Equatable, Sendable {
        case grid
        case play
    }

    var isOn: Bool {
        didSet {
            defaults.set(isOn, forKey: Self.key)
            if isOn { start() } else { focus = .grid }
        }
    }
    private(set) var focus: Focus = .grid
    var gridWidth: CGFloat = 0

    @ObservationIgnored weak var library: LibraryModel?
    @ObservationIgnored var play: @MainActor (Game) -> Void = { _ in }
    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored private var input = CouchInput()

    static let key = "controls.couchMode"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isOn = defaults.bool(forKey: Self.key)
    }

    var ringsGame: Bool { isOn && focus == .grid }
    var ringsPlay: Bool { isOn && focus == .play }

    func tick(_ state: PadState?, at time: Double) {
        guard isOn, let state else {
            input.reset()
            return
        }
        for command in input.commands(state, at: time) { perform(command) }
    }

    func perform(_ command: CouchCommand) {
        guard let library else { return }
        switch command {
        case .move(let direction):
            focus = .grid
            move(direction, in: library)
        case .previousList, .nextList:
            focus = .grid
            let lists = Self.lists(library)
            guard let at = lists.firstIndex(of: library.selection) else { return }
            let next = command == .nextList ? min(at + 1, lists.count - 1) : max(at - 1, 0)
            library.selection = lists[next]
            library.select(Self.games(library).first?.id)
        case .accept:
            switch focus {
            case .grid:
                guard let game = library.selectedGame ?? Self.games(library).first else { return }
                library.select(game.id)
                library.showPanel = true
                focus = .play
            case .play:
                if let game = library.selectedGame { play(game) }
            }
        case .back:
            focus = .grid
        }
    }

    func start() {
        guard isOn, let library, library.selectedGameID == nil else { return }
        library.select(Self.games(library).first?.id)
    }

    static func lists(_ library: LibraryModel) -> [SidebarItem] {
        let fixed: [SidebarItem] = [.all, .favorites] + GameSource.pc.map { .source($0) }
        let consoles = library.consoles.map { SidebarItem.source(.console($0)) }
        return (fixed + consoles).filter { $0 == .all || $0 == library.selection || library.badge($0) != nil }
    }

    static func sections(_ library: LibraryModel) -> [LibrarySection] {
        if case .grid(let sections) = library.screen { return sections }
        return []
    }

    static func games(_ library: LibraryModel) -> [Game] { sections(library).flatMap(\.games) }

    // As LazyVGrid's adaptive columns count them: 20 points of padding on each side, 18 between cards
    func columns(_ shape: CoverShape) -> Int {
        let minimum: CGFloat = shape == .square ? 170 : 150
        return max(1, Int((gridWidth - 40 + 18) / (minimum + 18)))
    }

    private func move(_ direction: CouchCommand.Direction, in library: LibraryModel) {
        let sections = Self.sections(library)
        guard !sections.isEmpty else { return }
        guard let id = library.selectedGameID,
              let s = sections.firstIndex(where: { $0.games.contains { $0.id == id } }),
              let i = sections[s].games.firstIndex(where: { $0.id == id })
        else {
            library.select(sections.first?.games.first?.id)
            return
        }
        let games = sections[s].games
        let width = columns(sections[s].shape)
        var target: Game?
        switch direction {
        case .left: target = i > 0 ? games[i - 1] : nil
        case .right: target = i + 1 < games.count ? games[i + 1] : nil
        case .down:
            if i + width < games.count {
                target = games[i + width]
            } else if s + 1 < sections.count, let next = sections[s + 1].games.first {
                target = sections[s + 1].games.indices.contains(i % width) ? sections[s + 1].games[i % width] : next
            }
        case .up:
            if i - width >= 0 {
                target = games[i - width]
            } else if s > 0 {
                let previous = sections[s - 1].games
                let lastRow = (previous.count - 1) / max(1, columns(sections[s - 1].shape)) * columns(sections[s - 1].shape)
                target = previous[min(lastRow + i % width, previous.count - 1)]
            }
        }
        if let target { library.select(target.id) }
    }
}
