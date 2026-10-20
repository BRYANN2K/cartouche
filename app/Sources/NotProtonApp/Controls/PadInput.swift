// What a controller holds right now, read from the Game Controller framework. Couch mode and Play with a controller both poll it, so neither takes the controller's handlers from the other.

import CoreGraphics
import Foundation
import GameController

struct PadState: Equatable, Sendable {
    var pressed: Set<PadButton> = []
    var leftStick = CGPoint.zero
    var rightStick = CGPoint.zero

    static let idle = PadState()
}

@MainActor
protocol PadReader: AnyObject {
    func read() -> PadState?
}

@MainActor
final class GameControllerPadReader: PadReader {

    func read() -> PadState? {
        guard let pad = (GCController.current ?? GCController.controllers().first)?.extendedGamepad else { return nil }
        var state = PadState()
        let buttons: [(PadButton, GCControllerButtonInput?)] = [
            (.south, pad.buttonA), (.east, pad.buttonB), (.west, pad.buttonX), (.north, pad.buttonY),
            (.leftShoulder, pad.leftShoulder), (.rightShoulder, pad.rightShoulder),
            (.leftTrigger, pad.leftTrigger), (.rightTrigger, pad.rightTrigger),
            (.leftStick, pad.leftThumbstickButton), (.rightStick, pad.rightThumbstickButton),
            (.back, pad.buttonOptions), (.start, pad.buttonMenu),
            (.up, pad.dpad.up), (.down, pad.dpad.down), (.left, pad.dpad.left), (.right, pad.dpad.right),
        ]
        for (button, input) in buttons where input?.isPressed == true {
            state.pressed.insert(button)
        }
        state.leftStick = CGPoint(x: Double(pad.leftThumbstick.xAxis.value), y: Double(pad.leftThumbstick.yAxis.value))
        state.rightStick = CGPoint(x: Double(pad.rightThumbstick.xAxis.value), y: Double(pad.rightThumbstick.yAxis.value))
        return state
    }
}
