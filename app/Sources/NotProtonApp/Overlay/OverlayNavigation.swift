import Foundation

enum OverlayKey: Equatable, Sendable {
    case up, down, left, right, enter, escape, tab, backTab, save
}

enum OverlayInput: Equatable, Sendable { case pointer, keyboard, controller }

// What a key asks the model to do beyond moving the focus or changing a setting
enum OverlayEffect: Equatable, Sendable {
    case close
    case save
    case run(OverlayRowID, sub: Int)
}

// Where the focus is, which confirmation is armed; no AppKit, so tests drive it directly
struct OverlayNavigation: Equatable, Sendable {
    enum Zone: Equatable, Sendable { case tabs, content }

    var section = OverlaySection.performance
    var zone = Zone.tabs
    var row = 0
    // The button inside a row with two (Pause, Quitter)
    var sub = 0
    var input = OverlayInput.pointer
    var quitArmed = false
    var armedApp: pid_t?
    // Direction of the last section change by pointer, for the content slide; 0 for none
    var slide = 0

    var showsKeyHelp: Bool { input != .pointer }
    var anyArmed: Bool { quitArmed || armedApp != nil }

    mutating func go(_ to: OverlaySection, by input: OverlayInput, zone: Zone = .tabs) {
        let all = OverlaySection.allCases
        let from = all.firstIndex(of: section) ?? 0, target = all.firstIndex(of: to) ?? 0
        slide = input == .pointer && to != section ? (target > from ? 1 : -1) : 0
        section = to
        self.zone = zone
        self.input = input
        row = 0
        sub = 0
        quitArmed = false
        armedApp = nil
    }

    // A click on the scrim: an armed confirmation is cancelled first, else the menu closes
    mutating func clickOutside() -> Bool {
        if anyArmed {
            quitArmed = false
            armedApp = nil
            return false
        }
        return true
    }

    mutating func handle(_ key: OverlayKey, rows: [OverlayRow], settings: inout OverlaySettings,
                         by input: OverlayInput = .keyboard) -> OverlayEffect? {
        self.input = input
        let all = OverlaySection.allCases
        let index = all.firstIndex(of: section) ?? 0
        switch key {
        case .save:
            return .save
        case .tab, .backTab:
            let step = key == .tab ? 1 : -1
            go(all[(index + step + all.count) % all.count], by: input, zone: zone)
            return nil
        default:
            break
        }
        if zone == .tabs {
            switch key {
            case .right: go(all[min(index + 1, all.count - 1)], by: input)
            case .left: go(all[max(index - 1, 0)], by: input)
            case .down, .enter:
                if !rows.isEmpty {
                    zone = .content
                    row = 0
                    sub = 0
                }
            case .escape: return .close
            default: break
            }
            return nil
        }
        row = min(max(0, row), max(0, rows.count - 1))
        let current = rows.indices.contains(row) ? rows[row] : nil
        switch key {
        case .down:
            row = min(row + 1, max(0, rows.count - 1))
            sub = 0
        case .up:
            if row == 0 { zone = .tabs } else { row -= 1 }
            sub = 0
        case .left, .right:
            if let current { return adjust(current, by: key == .right ? 1 : -1, settings: &settings) }
        case .enter:
            if let current { return activate(current, settings: &settings) }
        case .escape:
            zone = .tabs
            quitArmed = false
            armedApp = nil
        default:
            break
        }
        return nil
    }

    // ←→ on a row: one step of its value, or the next button of an app row
    mutating func adjust(_ row: OverlayRow, by step: Int, settings: inout OverlaySettings) -> OverlayEffect? {
        guard row.state == .normal else { return nil }
        switch row.control {
        case .segment(let options, let key):
            key.set(&settings, min(max(0, key.get(settings) + step), options.count - 1))
        case .corners:
            SettingKey.corner.set(&settings, min(max(0, settings.corner.rawValue + step), 3))
        case .slider(let key, let lo, let hi, let unit, _):
            let by = unit == 1 ? 2 : unit
            key.set(&settings, min(max(lo, key.get(settings) + step * by), hi))
        case .threshold(let value):
            return .run(.threshold, sub: min(max(30, value + step * 5), 95))
        case .toggle(let key):
            key.set(&settings, step > 0 ? 1 : 0)
        case .app:
            sub = min(max(0, sub + step), 1)
        default:
            break
        }
        return nil
    }

    mutating func activate(_ row: OverlayRow, settings: inout OverlaySettings) -> OverlayEffect? {
        guard row.state == .normal else { return nil }
        switch row.control {
        case .toggle(let key):
            key.set(&settings, key.get(settings) == 0 ? 1 : 0)
        case .segment(let options, let key):
            key.set(&settings, (key.get(settings) + 1) % options.count)
        case .corners:
            SettingKey.corner.set(&settings, (settings.corner.rawValue + 1) % 4)
        case .button, .fold:
            return .run(row.id, sub: 0)
        case .app:
            return .run(row.id, sub: sub)
        default:
            break
        }
        return nil
    }
}
