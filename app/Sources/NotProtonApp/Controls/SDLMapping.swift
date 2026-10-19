// A layout as SDL_GAMECONTROLLERCONFIG, which Wine's SDL backend (winebus.sys,
// bus_sdl.c) adds with SDL_GameControllerAddMapping. The game then sees an Xbox
// controller whose buttons follow the layout. No Wine patch is involved.
//
// SDL reads these controllers through its HIDAPI drivers, which number the
// buttons the same way for every model (SDL_CreateMappingForHIDAPIController):
// a mapping written in that order fits any of them. The GUID carries no CRC and
// no version, so SDL matches it on its second pass, whatever the firmware.

import Foundation

enum SDLMapping {

    struct Pad: Sendable {
        let family: PadFamily
        let vendor: UInt16
        let product: UInt16
        // Buttons past the standard 15 that SDL maps for this model
        var extras = ""
    }

    // Controllers the Game Controller framework names and SDL drives through HIDAPI
    static let pads: [Pad] = {
        let ps4 = "touchpad:b15,"
        let ps5 = "touchpad:b15,misc1:b16,"
        return [
            Pad(family: .playStation, vendor: 0x054c, product: 0x05c4, extras: ps4),
            Pad(family: .playStation, vendor: 0x054c, product: 0x09cc, extras: ps4),
            Pad(family: .playStation, vendor: 0x054c, product: 0x0ba0, extras: ps4),
            Pad(family: .playStation, vendor: 0x054c, product: 0x0ce6, extras: ps5),
            Pad(family: .playStation, vendor: 0x054c, product: 0x0df2, extras: ps5),
            Pad(family: .nintendo, vendor: 0x057e, product: 0x2009, extras: "misc1:b15,"),
        ] + [0x02d1, 0x02dd, 0x02e0, 0x02ea, 0x02fd, 0x0b00, 0x0b05, 0x0b20, 0x0b21, 0x0b22]
            .map { Pad(family: .xbox, vendor: 0x045e, product: UInt16($0)) }
        + [0x0b12, 0x0b13].map { Pad(family: .xbox, vendor: 0x045e, product: UInt16($0), extras: "misc1:b15,") }
    }()

    // USB and Bluetooth
    static let buses: [UInt16] = [0x03, 0x05]

    // SDL's GUID: bus, CRC, vendor, 0, product, 0, version, all 16-bit little
    // endian, then the driver: 'h' for HIDAPI
    static func guid(bus: UInt16, vendor: UInt16, product: UInt16) -> String {
        let words: [UInt16] = [bus, 0, vendor, 0, product, 0, 0]
        var bytes: [UInt8] = []
        for word in words { bytes += [UInt8(word & 0xff), UInt8(word >> 8)] }
        bytes += [UInt8(ascii: "h"), 0]
        return bytes.map { String(format: "%02x", Int($0)) }.joined()
    }

    // SDL's names for the buttons the game gets
    static func name(_ button: PadButton) -> String {
        switch button {
        case .south: "a"
        case .east: "b"
        case .west: "x"
        case .north: "y"
        case .leftShoulder: "leftshoulder"
        case .rightShoulder: "rightshoulder"
        case .leftTrigger: "lefttrigger"
        case .rightTrigger: "righttrigger"
        case .leftStick: "leftstick"
        case .rightStick: "rightstick"
        case .back: "back"
        case .start: "start"
        case .up: "dpup"
        case .down: "dpdown"
        case .left: "dpleft"
        case .right: "dpright"
        }
    }

    // Where HIDAPI reports each physical button: a button index, or the trigger's axis
    static func source(_ button: PadButton) -> String {
        switch button {
        case .south: "b0"
        case .east: "b1"
        case .west: "b2"
        case .north: "b3"
        case .back: "b4"
        case .start: "b6"
        case .leftStick: "b7"
        case .rightStick: "b8"
        case .leftShoulder: "b9"
        case .rightShoulder: "b10"
        case .up: "b11"
        case .down: "b12"
        case .left: "b13"
        case .right: "b14"
        case .leftTrigger: "a4"
        case .rightTrigger: "a5"
        }
    }

    // "a:b1,b:b0,…": the game's button, then the physical one that drives it
    static func fields(_ layout: ControllerLayout) -> String {
        var pairs = PadButton.allCases.map { button -> (String, String) in
            let target = layout.target(of: button)
            var from = source(button)
            // A trigger pulled halfway presses a button
            if button.isTrigger && !target.isTrigger { from = "+" + from }
            return (name(target), from)
        }
        pairs.append(("guide", "b5"))
        let sticks = layout.swapSticks ? ["a2", "a3", "a0", "a1"] : ["a0", "a1", "a2", "a3"]
        pairs += zip(["leftx", "lefty", "rightx", "righty"], sticks).map { ($0, $1) }
        return pairs.sorted { ($0.0, $0.1) < ($1.0, $1.1) }.map { "\($0):\($1)," }.joined()
    }

    // One line per model and bus, or nil for the standard layout, which needs none.
    // The name "*" keeps the controller's own name, which games read.
    static func config(_ layout: ControllerLayout) -> String? {
        guard !layout.isStandard else { return nil }
        let fields = fields(layout)
        return pads.flatMap { pad in
            buses.map { "\(guid(bus: $0, vendor: pad.vendor, product: pad.product)),*,\(fields)\(pad.extras)" }
        }
        .joined(separator: "\n")
    }

    static let variable = "SDL_GAMECONTROLLERCONFIG"
}
