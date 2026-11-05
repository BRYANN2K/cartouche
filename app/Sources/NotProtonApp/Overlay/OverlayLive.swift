import Foundation

// The game's numbers for the last second, from the library's block or from outside the game
struct GameMetrics: Equatable, Sendable {
    var presentedFPS: Double
    var realFPS: Double?
    var low1FPS: Double
    var frameMs: Double
    var latencyMs: Double?
    var cpuPercent: Double?
    var gpuPercent: Double?
    var ramBytes: UInt64?
    var thermal: Int
    var upscale: UpscaleMode = .off
    var upscaleOut = CGSize.zero
    var frameGenFactor = 1
    var neuralEngine = false
    // Measured outside the game: the 1 % low is an approximation
    var external = false
    var frameTimes: [Double] = []
}

struct MacReadings: Equatable, Sendable {
    var cpuPercent: Double?
    var gpuPercent: Double?
    var gameGPUPercent: Double?
    var gpuWatts: Double?
    var memoryBytes: UInt64?
    // The whole Mac's memory, as « Ce Mac » shows it: used over the RAM, pressure by colour only
    var memoryUsed: UInt64?
    var memoryTotal: UInt64?
    var memoryPressure = MemoryPressure.normal
    var thermal = 0
    var battery: Int?
    var lowPower = false
}

struct OverlayApp: Identifiable, Equatable, Sendable {
    var id: pid_t { pid }
    var pid: pid_t
    var name: String
    var cpu: Double
    var gpu: Double
    var memoryGB: Double
    var paused = false
    var system = false
}

struct OverlayLive: Equatable, Sendable {
    var metrics: GameMetrics?
    var mac = MacReadings()
    var apps: [OverlayApp] = []
    // Every app but the game, as a percent of the whole Mac's CPU
    var othersCPU: Double = 0
    var captureAllowed = true
    var controller: ControllerInfo?
    var sessionStart = Date()

    var top: OverlayApp? { apps.filter { !$0.paused && !$0.system }.max { $0.cpu < $1.cpu } }
}

enum Thermal {
    static func name(_ state: Int) -> String {
        switch state {
        case 1: ot("Fair")
        case 2: ot("Serious")
        case 3: ot("Critical")
        default: ot("Nominal")
        }
    }
}
