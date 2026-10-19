import Foundation
import GameController
import Testing

@testable import NotProtonApp

// Controllers as the Game Controller framework would report them, without one
@MainActor
final class FakeControllerSource: ControllerSource {
    var controllers: [ControllerInfo] = []
    private var changed: (@MainActor () -> Void)?
    var started = 0

    func start(_ changed: @escaping @MainActor () -> Void) {
        started += 1
        self.changed = changed
    }

    func stop() { changed = nil }

    func connect(_ info: ControllerInfo) {
        controllers.append(info)
        changed?()
    }

    func disconnect(_ id: String) {
        controllers.removeAll { $0.id == id }
        changed?()
    }

    func setBattery(_ id: String, _ level: Double, charging: Bool = false) {
        guard let i = controllers.firstIndex(where: { $0.id == id }) else { return }
        controllers[i].battery = level
        controllers[i].charging = charging
        changed?()
    }

    static let dualSense = ControllerInfo(id: "pad1", name: "DualSense Wireless Controller", shortName: "DualSense",
                                          family: .playStation, battery: 0.8)
    static let xbox = ControllerInfo(id: "pad2", name: "Xbox Wireless Controller", shortName: "Xbox One",
                                     family: .xbox, battery: nil)
}

@Suite("Controller status")
@MainActor
struct ControllerMonitorTests {

    @Test("A DualSense connecting shows by name with its battery, well within 2 seconds")
    func dualSenseConnects() {
        let source = FakeControllerSource()
        let monitor = ControllerMonitor(source: source)
        monitor.start()
        #expect(monitor.controllers.isEmpty)
        let asked = ContinuousClock.now
        source.connect(FakeControllerSource.dualSense)
        let took = ContinuousClock.now - asked
        #expect(monitor.primary?.shortName == "DualSense")
        #expect(monitor.primary?.name == "DualSense Wireless Controller")
        #expect(monitor.primary?.batteryText == "80%")
        #expect(monitor.primary?.status == "Battery 80%")
        #expect(took < .seconds(2), "shown after \(took)")
    }

    @Test("Battery changes and disconnections follow; a wired controller says Connected")
    func followsChanges() {
        let source = FakeControllerSource()
        let monitor = ControllerMonitor(source: source)
        monitor.start()
        source.connect(FakeControllerSource.dualSense)
        source.connect(FakeControllerSource.xbox)
        source.setBattery("pad1", 0.35, charging: true)
        #expect(monitor.controllers.map(\.shortName) == ["DualSense", "Xbox One"])
        #expect(monitor.controllers[0].status == "Charging, battery 35%")
        #expect(monitor.controllers[1].status == "Connected")
        source.disconnect("pad1")
        #expect(monitor.primary?.shortName == "Xbox One")
        source.disconnect("pad2")
        #expect(monitor.primary == nil)
    }

    @Test("Starting twice listens once")
    func startsOnce() {
        let source = FakeControllerSource()
        let monitor = ControllerMonitor(source: source)
        monitor.start()
        monitor.start()
        #expect(source.started == 1)
    }

    @Test("A controller the framework makes up reads as a generic pad with no battery")
    func frameworkController() {
        let controller = GCController.withExtendedGamepad()
        let info = ControllerInfo(controller)
        #expect(info.family == .generic)
        #expect(info.battery == nil)
        #expect(info.status == "Connected")
        #expect(!info.name.isEmpty || info.shortName.isEmpty)
    }

    @Test("Percentages round to whole numbers")
    func rounding() {
        var info = FakeControllerSource.dualSense
        info.battery = 0.666
        #expect(info.batteryText == "67%")
        info.battery = 1
        #expect(info.batteryText == "100%")
    }
}
