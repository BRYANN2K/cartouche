import CoreGraphics
import Foundation

// The keys the remap list offers, with macOS virtual key codes (HIToolbox Events.h)
enum MacKey: String, Codable, CaseIterable, Identifiable, Sendable {
    case a, b, c, d, e, f, g, h, i, j, k, l, m, n, o, p, q, r, s, t, u, v, w, x, y, z
    case one, two, three, four, five, six, seven, eight, nine, zero
    case space, returnKey, tab, escape, delete
    case shift, control, option, command, capsLock
    case up, down, left, right

    var id: String { rawValue }

    var code: CGKeyCode {
        switch self {
        case .a: 0
        case .s: 1
        case .d: 2
        case .f: 3
        case .h: 4
        case .g: 5
        case .z: 6
        case .x: 7
        case .c: 8
        case .v: 9
        case .b: 11
        case .q: 12
        case .w: 13
        case .e: 14
        case .r: 15
        case .y: 16
        case .t: 17
        case .one: 18
        case .two: 19
        case .three: 20
        case .four: 21
        case .six: 22
        case .five: 23
        case .nine: 25
        case .seven: 26
        case .eight: 28
        case .zero: 29
        case .o: 31
        case .u: 32
        case .i: 34
        case .p: 35
        case .returnKey: 36
        case .l: 37
        case .j: 38
        case .k: 40
        case .n: 45
        case .m: 46
        case .tab: 48
        case .space: 49
        case .delete: 51
        case .escape: 53
        case .command: 55
        case .shift: 56
        case .capsLock: 57
        case .option: 58
        case .control: 59
        case .left: 123
        case .right: 124
        case .down: 125
        case .up: 126
        }
    }

    var label: String {
        switch self {
        case .one: "1"
        case .two: "2"
        case .three: "3"
        case .four: "4"
        case .five: "5"
        case .six: "6"
        case .seven: "7"
        case .eight: "8"
        case .nine: "9"
        case .zero: "0"
        case .space: String(localized: "Space")
        case .returnKey: "↩"
        case .tab: "⇥"
        case .escape: "⎋"
        case .delete: "⌫"
        case .shift: "⇧"
        case .control: "⌃"
        case .option: "⌥"
        case .command: "⌘"
        case .capsLock: "⇪"
        case .up: "↑"
        case .down: "↓"
        case .left: "←"
        case .right: "→"
        default: rawValue.uppercased()
        }
    }

    // Modifiers come as flag changes, which the tap does not rewrite
    var isModifier: Bool { [.shift, .control, .option, .command, .capsLock].contains(self) }
}

struct KeyRemap: Codable, Equatable, Hashable, Sendable {
    var from: MacKey
    var to: MacKey

    static func table(_ remaps: [KeyRemap]) -> [CGKeyCode: CGKeyCode] {
        var table: [CGKeyCode: CGKeyCode] = [:]
        for remap in remaps where remap.from != remap.to && !remap.from.isModifier && !remap.to.isModifier {
            table[remap.from.code] = remap.to.code
        }
        return table
    }
}
