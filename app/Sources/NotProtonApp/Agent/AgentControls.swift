import Foundation
import RetroArchKit
import UserNotifications

// The controls tools: the agent reads and writes the same GameControls the
// Controls sheet does, so an SDL mapping, a RetroArch remap or the Mac
// driver keys land exactly where a user's choice would. Steam games stay
// refused — Steam Input owns their layout.
struct AgentControls: AgentToolProvider {

    func tools() -> [AgentTool] {
        [
            AgentTool(
                name: "list_controllers",
                detail: "The controllers macOS sees: name, family "
                    + "(playStation, xbox, nintendo, generic), battery level "
                    + "and charging. Pairing stays macOS's job.",
                schema: .object(["type": "object"]),
                run: { backend, _ in
                    ["controllers": .array(backend.controllers().map {
                        .object([
                            "name": .string($0.name),
                            "family": .string($0.family.rawValue),
                            "battery": $0.battery.map { .number($0) } ?? .null,
                            "charging": .bool($0.charging),
                        ])
                    })]
                }
            ),

            AgentTool(
                name: "get_controls",
                detail: "Who handles the game's layout (steam_input, cartouche "
                    + "or retroarch) and the current choices: button mapping, "
                    + "keyboard options, key remaps and Play with a controller.",
                schema: AgentTools.gameArg(),
                run: { backend, args in
                    let game = try AgentTools.find(backend, args)
                    let controls = backend.gameControls(game.id)
                    var out: [String: JSONValue] = [
                        "game": .string(game.name),
                        "handler": .string(Self.handler(ControlsHandler(game))),
                        "layout": Self.layoutJSON(controls.layout),
                        "keyboard": Self.keyboardJSON(controls.keyboard, set: controls.keyboardSet),
                        "remap_keys": .bool(controls.remapKeys),
                        "key_remaps": .array(controls.keyRemaps.map {
                            .object(["from": .string($0.from.rawValue),
                                     "to": .string($0.to.rawValue)])
                        }),
                        "play_with_controller": .bool(controls.playWithController),
                        "accessibility": .string(backend.controlsAccessibility() ? "granted" : "not granted"),
                    ]
                    if ControlsHandler(game) == .steamInput {
                        out["note"] = .string("Steam Input owns this game's layout; "
                            + "Cartouche only writes its Mac driver keyboard options.")
                    }
                    return .object(out)
                }
            ),

            AgentTool(
                name: "set_controls",
                detail: "Change the game's controller layout. \"preset\": "
                    + "standard, southpaw or swap_ab; \"buttons\" maps a pressed "
                    + "button to the one the game gets (south, east, leftStick…); "
                    + "\"swap_sticks\" trades the sticks. Steam games are "
                    + "refused: Steam Input owns their layout.",
                schema: .object([
                    "type": "object",
                    "properties": .object([
                        "game": ["type": "string"],
                        "preset": ["type": "string",
                                   "enum": .array([.string("standard"), .string("southpaw"), .string("swap_ab")])],
                        "buttons": ["type": "object",
                                    "description": .string("pressed PadButton -> PadButton the game gets")],
                        "swap_sticks": ["type": "boolean"],
                    ]),
                    "required": ["game"],
                ]),
                level: .standard, readOnly: false,
                run: { backend, args in
                    let game = try AgentTools.findStrict(backend, args)
                    guard ControlsHandler(game) != .steamInput else {
                        throw AgentToolError("Steam Input handles \(game.name)'s layout; "
                            + "change it in Steam, on the game's page")
                    }
                    var controls = backend.gameControls(game.id)
                    if let preset = args["preset"]?.string {
                        controls.layout = try Self.preset(preset)
                    }
                    if let buttons = args["buttons"]?.object {
                        for (pressed, target) in buttons {
                            guard let from = PadButton(rawValue: pressed),
                                  let to = target.string.flatMap({ PadButton(rawValue: $0) }) else {
                                throw AgentToolError("unknown button in \"\(pressed)\": "
                                    + "pad buttons are \(PadButton.allCases.map(\.rawValue).joined(separator: ", "))")
                            }
                            controls.layout.set(from, sends: to)
                        }
                    }
                    if let swap = args["swap_sticks"]?.bool { controls.layout.swapSticks = swap }
                    try await backend.setGameControls(controls, for: game.id)
                    return ["layout": Self.layoutJSON(controls.layout), "applied_next_launch": .bool(true)]
                }
            ),

            AgentTool(
                name: "set_keyboard_mouse",
                detail: "The Wine Mac driver's options for the game: "
                    + "\"command_as_control\", \"option_as_alt\", "
                    + "\"keep_mouse_inside\", \"precise_scrolling\". Applied to "
                    + "the game's prefix at the next launch.",
                schema: .object([
                    "type": "object",
                    "properties": .object([
                        "game": ["type": "string"],
                        "command_as_control": ["type": "boolean"],
                        "option_as_alt": ["type": "boolean"],
                        "keep_mouse_inside": ["type": "boolean"],
                        "precise_scrolling": ["type": "boolean"],
                    ]),
                    "required": ["game"],
                ]),
                level: .standard, readOnly: false,
                run: { backend, args in
                    let game = try AgentTools.findStrict(backend, args)
                    guard ControlsHandler(game) != .retroArch else {
                        throw AgentToolError("\(game.name) is a console game; "
                            + "it has no Windows keyboard options")
                    }
                    var controls = backend.gameControls(game.id)
                    if let on = args["command_as_control"]?.bool { controls.keyboard.commandAsControl = on }
                    if let on = args["option_as_alt"]?.bool { controls.keyboard.optionAsAlt = on }
                    if let on = args["keep_mouse_inside"]?.bool { controls.keyboard.keepMouseInside = on }
                    if let on = args["precise_scrolling"]?.bool { controls.keyboard.preciseScrolling = on }
                    controls.keyboardSet = true
                    try await backend.setGameControls(controls, for: game.id)
                    return ["keyboard": Self.keyboardJSON(controls.keyboard, set: true),
                            "applied_next_launch": .bool(true)]
                }
            ),

            AgentTool(
                name: "set_controller_for_keyboard_game",
                detail: "Turn Play with a controller on or off for a game that "
                    + "only takes a keyboard: left stick to WASD, right stick "
                    + "to the mouse, buttons to keys. Needs Accessibility "
                    + "access, which only the app may ask macOS for.",
                schema: .object([
                    "type": "object",
                    "properties": .object([
                        "game": ["type": "string"],
                        "on": ["type": "boolean"],
                    ]),
                    "required": ["game", "on"],
                ]),
                level: .standard, readOnly: false,
                run: { backend, args in
                    let game = try AgentTools.findStrict(backend, args)
                    let on = args["on"]?.bool ?? true
                    guard ControlsHandler(game) != .retroArch else {
                        throw AgentToolError("\(game.name) is a console game; "
                            + "its controller works through RetroArch")
                    }
                    if on && !backend.controlsAccessibility() {
                        throw AgentToolError("Play with a controller needs Accessibility "
                            + "access for Cartouche; turn it on in the game's Controls "
                            + "in Cartouche so the app can ask macOS")
                    }
                    var controls = backend.gameControls(game.id)
                    controls.playWithController = on
                    try await backend.setGameControls(controls, for: game.id)
                    return ["play_with_controller": .bool(on)]
                }
            ),
        ]
    }

    // MARK: - Shaping

    static func handler(_ handler: ControlsHandler) -> String {
        switch handler {
        case .steamInput: "steam_input"
        case .cartouche: "cartouche"
        case .retroArch: "retroarch"
        }
    }

    static func preset(_ name: String) throws -> ControllerLayout {
        switch name {
        case "standard": return .preset(.standard)
        case "southpaw": return .preset(.southpaw)
        case "swap_ab", "swapAB": return .preset(.swapAB)
        default: throw AgentToolError("unknown preset \"\(name)\"; "
            + "presets are standard, southpaw, swap_ab")
        }
    }

    static func layoutJSON(_ layout: ControllerLayout) -> JSONValue {
        .object([
            "preset": layout.preset.map { .string($0 == .swapAB ? "swap_ab" : $0.rawValue) } ?? .string("custom"),
            "buttons": .object(layout.buttons.mapValues { .string($0.rawValue) }
                .reduce(into: [:]) { $0[$1.key.rawValue] = $1.value }),
            "swap_sticks": .bool(layout.swapSticks),
        ])
    }

    static func keyboardJSON(_ keyboard: KeyboardOptions, set: Bool) -> JSONValue {
        .object([
            "command_as_control": .bool(keyboard.commandAsControl),
            "option_as_alt": .bool(keyboard.optionAsAlt),
            "keep_mouse_inside": .bool(keyboard.keepMouseInside),
            "precise_scrolling": .bool(keyboard.preciseScrolling),
            "applied": .bool(set),
        ])
    }

}

// Approval alerts outside the app window: "Claude wants to…" with Allow/Deny.
// The answer itself always goes through AgentService.answer — a notification
// tap just brings the app forward; the buttons answer directly. Everything goes
// through NotificationRouter, the app's one notification delegate.
enum AgentNotifier {

    static let category = "CARTOUCHE_AGENT_APPROVAL"
    static let allowAction = "allow"
    static let denyAction = "deny"

    // Answered in the app or timed out: the alert goes away. The center only exists in an .app bundle.
    static func dismiss(_ id: UUID) {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id.uuidString])
    }
    // The live answer hop; tests swap it.
    @MainActor static var onAnswer: @MainActor (UUID, Bool) -> Void = { _, _ in }

    // Called once at launch so a tap on a notification from a previous run still answers
    @MainActor
    static func register(in router: NotificationRouter = .shared) {
        router.handle(category: category) { action, info in
            guard let id = info["approval"].flatMap(UUID.init(uuidString:)) else { return }
            switch action {
            case allowAction: Self.onAnswer(id, true)
            case denyAction: Self.onAnswer(id, false)
            default: break
            }
        }
    }

    @MainActor
    static func post(_ approval: AgentApproval, router: NotificationRouter = .shared) {
        register(in: router)
        router.post(NotificationSpec(
            identifier: approval.id.uuidString,
            title: String(localized: "Cartouche agent request"),
            body: approval.text,
            category: category,
            actions: [NotificationButton(id: allowAction, title: String(localized: "Allow"), requiresUnlock: true),
                      NotificationButton(id: denyAction, title: String(localized: "Deny"))],
            userInfo: ["approval": approval.id.uuidString]))
    }
}
