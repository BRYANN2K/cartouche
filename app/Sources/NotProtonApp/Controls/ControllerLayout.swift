// A game's controller layout: what the game gets when each button is pressed.
// Buttons are named by position, so one layout fits every controller family.

import Foundation

enum PadButton: String, Codable, CodingKeyRepresentable, CaseIterable, Identifiable, Sendable {
    // The face buttons by position: Cross, Circle, Square, Triangle on a DualSense
    case south, east, west, north
    case leftShoulder, rightShoulder, leftTrigger, rightTrigger
    case leftStick, rightStick
    case back, start
    case up, down, left, right

    var id: String { rawValue }

    var isTrigger: Bool { self == .leftTrigger || self == .rightTrigger }

    // The physical button on this family's controller
    func label(_ family: PadFamily) -> String {
        switch (self, family) {
        case (.south, .playStation): "Cross"
        case (.east, .playStation): "Circle"
        case (.west, .playStation): "Square"
        case (.north, .playStation): "Triangle"
        case (.south, .nintendo): "B"
        case (.east, .nintendo): "A"
        case (.west, .nintendo): "Y"
        case (.north, .nintendo): "X"
        case (.leftShoulder, .playStation): "L1"
        case (.rightShoulder, .playStation): "R1"
        case (.leftTrigger, .playStation): "L2"
        case (.rightTrigger, .playStation): "R2"
        case (.leftStick, .playStation): "L3"
        case (.rightStick, .playStation): "R3"
        case (.back, .playStation): "Create"
        case (.start, .playStation): "Options"
        case (.leftShoulder, .nintendo): "L"
        case (.rightShoulder, .nintendo): "R"
        case (.leftTrigger, .nintendo): "ZL"
        case (.rightTrigger, .nintendo): "ZR"
        case (.back, .nintendo): "−"
        case (.start, .nintendo): "+"
        default: xbox
        }
    }

    // What a Windows game sees through SDL: an Xbox controller
    var xbox: String {
        switch self {
        case .south: "A"
        case .east: "B"
        case .west: "X"
        case .north: "Y"
        case .leftShoulder: "LB"
        case .rightShoulder: "RB"
        case .leftTrigger: "LT"
        case .rightTrigger: "RT"
        case .leftStick: "LS"
        case .rightStick: "RS"
        case .back: "View"
        case .start: "Menu"
        case .up, .down, .left, .right: direction
        }
    }

    // What a console core sees: RetroArch's RetroPad, shaped like a SNES pad
    var retroPad: String {
        switch self {
        case .south: "B"
        case .east: "A"
        case .west: "Y"
        case .north: "X"
        case .leftShoulder: "L"
        case .rightShoulder: "R"
        case .leftTrigger: "L2"
        case .rightTrigger: "R2"
        case .leftStick: "L3"
        case .rightStick: "R3"
        case .back: "Select"
        case .start: "Start"
        case .up, .down, .left, .right: direction
        }
    }

    private var direction: String {
        switch self {
        case .up: String(localized: "D-pad Up")
        case .down: String(localized: "D-pad Down")
        case .left: String(localized: "D-pad Left")
        default: String(localized: "D-pad Right")
        }
    }
}

struct ControllerLayout: Codable, Equatable, Sendable {
    // What the game gets for a button; a button left out sends itself
    var buttons: [PadButton: PadButton] = [:]
    var swapSticks = false

    enum Preset: String, CaseIterable, Identifiable, Sendable {
        case standard, southpaw, swapAB

        var id: String { rawValue }

        var title: String {
            switch self {
            case .standard: String(localized: "Default")
            case .southpaw: String(localized: "Southpaw")
            case .swapAB: String(localized: "Swap A/B")
            }
        }
    }

    static let standard = ControllerLayout()

    static func preset(_ preset: Preset) -> ControllerLayout {
        switch preset {
        case .standard: ControllerLayout()
        // The sticks trade places, their clicks with them
        case .southpaw: ControllerLayout(buttons: [.leftStick: .rightStick, .rightStick: .leftStick], swapSticks: true)
        case .swapAB: ControllerLayout(buttons: [.south: .east, .east: .south])
        }
    }

    // The preset this layout is, if any
    var preset: Preset? { Preset.allCases.first { Self.preset($0) == self } }

    var isStandard: Bool { self == .standard }

    func target(of button: PadButton) -> PadButton { buttons[button] ?? button }

    // Identity entries are dropped, so equal layouts compare equal
    mutating func set(_ button: PadButton, sends target: PadButton) {
        buttons[button] = target == button ? nil : target
    }
}
