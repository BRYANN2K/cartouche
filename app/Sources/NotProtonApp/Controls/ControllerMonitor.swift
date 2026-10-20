// The controllers macOS sees, with their name and battery, from Apple's Game Controller framework. Pairing stays macOS's job, so no Bluetooth access is asked.

import Foundation
import GameController
import Observation

enum PadFamily: String, Codable, Sendable {
    case playStation, xbox, nintendo, generic
}

struct ControllerInfo: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var shortName: String
    var family: PadFamily
    var battery: Double?
    var charging = false

    var batteryText: String? {
        battery.map { "\(Int(($0 * 100).rounded()))%" }
    }

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

@MainActor
protocol ControllerSource: AnyObject {
    var controllers: [ControllerInfo] { get }
    func start(_ changed: @escaping @MainActor () -> Void)
    func stop()
    func pollBattery(_ on: Bool)
}

extension ControllerSource {
    func pollBattery(_ on: Bool) {}
}

@MainActor
final class GameControllerSource: ControllerSource {

    private var observers: [any NSObjectProtocol] = []
    private var poll: Task<Void, Never>?
    private var last: [ControllerInfo] = []
    private var changed: (@MainActor () -> Void)?
    private var wantsBattery = false
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
        self.changed = changed
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { changed() }
            })
        }
        updatePoll()
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        changed = nil
        updatePoll()
    }

    func pollBattery(_ on: Bool) {
        wantsBattery = on
        updatePoll()
    }

    private func updatePoll() {
        guard wantsBattery, changed != nil, poll == nil else {
            if !wantsBattery || changed == nil { poll?.cancel(); poll = nil }
            return
        }
        poll = Task { [weak self, interval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self else { return }
                let now = self.controllers
                guard !now.isEmpty else { self.last = []; continue }
                if now != self.last {
                    self.last = now
                    self.changed?()
                }
            }
        }
    }
}

@MainActor
@Observable
final class ControllerMonitor {

    private(set) var controllers: [ControllerInfo] = []
    @ObservationIgnored let source: any ControllerSource
    @ObservationIgnored private var started = false
    @ObservationIgnored private var batteryViewers = 0

    init(source: any ControllerSource) {
        self.source = source
    }

    var primary: ControllerInfo? { controllers.first }

    func start() {
        guard !started else { return }
        started = true
        source.start { [weak self] in self?.refresh() }
        refresh()
    }

    func batteryShown(_ on: Bool) {
        let was = batteryViewers > 0
        batteryViewers = max(0, batteryViewers + (on ? 1 : -1))
        let isOn = batteryViewers > 0
        if isOn != was { source.pollBattery(isOn) }
    }

    func refresh() {
        let now = source.controllers
        if now != controllers { controllers = now }
    }
}
