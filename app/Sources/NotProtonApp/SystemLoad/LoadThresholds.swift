import Darwin
import Foundation

struct LoadThresholds: Codable, Equatable, Sendable {
    var enabled = true
    // Percent of the whole Mac's CPU used by everything but the game; one value for the app and the menu
    var otherCPU: Double = 60
    var memory: MemoryPressure = .warning
    // Percent of the GPU used by other apps; WindowServer draws the game too, so it is left out
    var otherGPU: Double = 60

    static let key = "resources.thresholds"

    static func load(_ defaults: UserDefaults = .standard) -> LoadThresholds {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(LoadThresholds.self, from: $0) } ?? LoadThresholds()
    }

    func save(_ defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
    }
}

enum LoadReason: Equatable, Sendable {
    case cpu(Double)
    case memory(MemoryPressure)
    case gpu(Double)

    var text: String {
        switch self {
        case .cpu(let value): String(localized: "Other apps use \(Int(value.rounded()))% of the CPU.")
        case .memory(.critical): String(localized: "Memory is critically low.")
        case .memory: String(localized: "Memory is under pressure.")
        case .gpu(let value): String(localized: "Other apps use \(Int(value.rounded()))% of the GPU.")
        }
    }
}

struct LoadVerdict: Equatable, Sendable {
    var reasons: [LoadReason]
    var top: [ResourceUsage]
}

enum LoadCheck {

    static let windowServer = "WindowServer"

    // The whole Mac's busy CPU minus the game's share
    static func otherCPU(_ sample: ResourceSample, game: Set<pid_t>) -> Double {
        let gameCPU = sample.cpuByPID.filter { game.contains($0.key) }.values.reduce(0, +) / Double(sample.cores)
        return max(0, sample.cpuLoad - gameCPU)
    }

    // nil when the driver cannot tell the game's GPU time from the rest while it plays
    static func otherGPU(_ sample: ResourceSample, game: Set<pid_t>) -> Double? {
        guard sample.gpuPerProcess else { return game.isEmpty ? sample.gpuDevice : nil }
        let others = sample.gpuByPID.filter { pid, _ in 
            !game.contains(pid) && (sample.processes[pid]?.name ?? sample.gpuNames[pid]) != windowServer
        }
        return min(100, others.values.reduce(0, +))
    }

    static func reasons(_ sample: ResourceSample, game: Set<pid_t>, thresholds: LoadThresholds) -> [LoadReason] {
        guard thresholds.enabled else { return [] }
        var reasons: [LoadReason] = []
        let cpu = otherCPU(sample, game: game)
        if cpu >= thresholds.otherCPU { reasons.append(.cpu(cpu)) }
        if sample.memory.pressure >= thresholds.memory { reasons.append(.memory(sample.memory.pressure)) }
        if let gpu = otherGPU(sample, game: game), gpu >= thresholds.otherGPU { reasons.append(.gpu(gpu)) }
        return reasons
    }

    // The three heaviest rows the user can act on, by what crossed the line first
    static func top(_ sample: ResourceSample, reasons: [LoadReason], excluded: Set<pid_t>, count: Int = 3) -> [ResourceUsage] {
        let rows = sample.rows.filter { row in !row.pids.contains(where: excluded.contains) }
        let sorted: [ResourceUsage]
        switch reasons.first {
        case .memory: sorted = rows.sorted { ($0.memory ?? 0) > ($1.memory ?? 0) }
        case .gpu: sorted = rows.sorted { ($0.gpu ?? 0) > ($1.gpu ?? 0) }
        default: sorted = rows.sorted { ($0.cpu ?? 0) > ($1.cpu ?? 0) }
        }
        return Array(sorted.prefix(count))
    }

    static func verdict(_ sample: ResourceSample, game: Set<pid_t>, protected: Set<pid_t>,
                        thresholds: LoadThresholds) -> LoadVerdict? {
        let reasons = reasons(sample, game: game, thresholds: thresholds)
        guard !reasons.isEmpty else { return nil }
        return LoadVerdict(reasons: reasons, top: top(sample, reasons: reasons, excluded: protected.union(game)))
    }
}
