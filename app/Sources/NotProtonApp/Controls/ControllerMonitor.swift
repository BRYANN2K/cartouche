// The controllers macOS sees, with their name and battery, from Apple's Game
// Controller framework. Pairing stays macOS's job, so no Bluetooth access is asked.

import Foundation
import GameController
import Observation

// Whose button names a controller carries
enum PadFamily: String, Codable, Sendable {
    case playStation, xbox, nintendo, generic
}

struct ControllerInfo: Identifiable, Equatable, Sendable {
    var id: String
    // "DualSense Wireless Controller", as Settings > Controllers lists it
    var name: String
    // "DualSense", as the game panel shows it
    var shortName: String
    var family: PadFamily
    // 0 to 1; nil for a wired controller or one that does not say
    var battery: Double?
    var charging = false

    var batteryText: String? {
        battery.map { "\(Int(($0 * 100).rounded()))%" }
    }

    // "Battery 80%", "Charging, battery 80%", "Connected"
    var status: String {
        guard let percent = batteryText else { return String(localized: "Connected") }
        return charging ? String(localized: "Charging, battery \(percent)") : String(localized: "Battery \(percent)")
    }
}

extension ControllerInfo {
    init(_ controller: GCController) {
        let category = controller.productCategory
        let vendor = controller.vendorName
        id = String(UInt(bitPattern: ObjectIdentifier(controller).hashValue))
        name = vendor ?? category
        // The category names the model ("DualSense", "Xbox One"); generic ones say nothing
        shortName = ["", "Gamepad", "MFi", "HID"].contains(category) ? (vendor ?? category) : category
        family = Self.family(of: controller)
        if let battery = controller.battery, battery.batteryState != .unknown {
            self.battery = Double(battery.batteryLevel)
            charging = battery.batteryState == .charging
        }
    }

    static func family(of controller: GCController) -> PadFamily {
        switch controller.extendedGamepad {
        case is GCDualSenseGamepad, is GCDualShockGamepad: return .playStation
        case is GCXboxGamepad: return .xbox
        default: break
        }
        let category = controller.productCategory.lowercased()
        if category.contains("switch") || category.contains("joy-con") { return .nintendo }
        if category.contains("dualsense") || category.contains("dualshock") { return .playStation }
        if category.contains("xbox") { return .xbox }
        return .generic
    }
}

// Where the list comes from: the framework, or a stand-in in tests
@MainActor
protocol ControllerSource: AnyObject {
    var controllers: [ControllerInfo] { get }
    // `changed` runs on each connection, disconnection and battery change
    func start(_ changed: @escaping @MainActor () -> Void)
    func stop()
}

@MainActor
final class GameControllerSource: ControllerSource {

    private var observers: [any NSObjectProtocol] = []
    private var poll: Task<Void, Never>?
    private var last: [ControllerInfo] = []
    // The framework posts no battery change, so it is read again this often
    let interval: Duration

    init(interval: Duration = .seconds(1)) {
        self.interval = interval
    }

    var controllers: [ControllerInfo] {
        GCController.controllers().map(ControllerInfo.init)
    }

    func start(_ changed: @escaping @MainActor () -> Void) {
        guard observers.isEmpty else { return }
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { changed() }
            })
        }
        poll = Task { [weak self, interval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self else { return }
                let now = self.controllers
                if now != self.last {
                    self.last = now
                    changed()
                }
            }
        }
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        poll?.cancel()
        poll = nil
    }
}

@MainActor
@Observable
final class ControllerMonitor {

    private(set) var controllers: [ControllerInfo] = []
    @ObservationIgnored let source: any ControllerSource
    @ObservationIgnored private var started = false

    init(source: any ControllerSource) {
        self.source = source
    }

    // The one the game panel names: the first connected
    var primary: ControllerInfo? { controllers.first }

    func start() {
        guard !started else { return }
        started = true
        source.start { [weak self] in self?.refresh() }
        refresh()
    }

    func refresh() {
        let now = source.controllers
        if now != controllers { controllers = now }
    }
}
