
import Foundation

struct CompatEstimate: Equatable, Sendable {

    let rating: CompatRating
    let fps: Int?
    let settings: GraphicsSettings?
    let reportCount: Int
    let sameChipCount: Int
    let chip: String

    enum Result: Equatable, Sendable {
        case estimate(CompatEstimate)
        case noReports
        case unknownMac
    }

    static let reach = 1.4
    static let fewest = 3
    static let fallback = 5

    static func compute(
        reports: [MacReport], method: PlayMethod, chip: String?, gpu: [String: Double]
    ) -> Result {
        let rows = reports.filter { $0.method == method && gpu[$0.chip].map { $0 > 0 } == true }
        guard !rows.isEmpty else { return .noReports }
        guard let chip, let mine = gpu[chip] else { return .unknownMac }

        func distance(_ r: MacReport) -> Double { abs(log(gpu[r.chip]! / mine)) }
        var near = rows.filter { distance($0) <= log(reach) }
        let usedFallback = near.count < fewest
        if usedFallback {
            near = Array(rows.enumerated()
                .sorted { (distance($0.element), $0.offset) < (distance($1.element), $1.offset) }
                .prefix(fallback).map(\.element))
        }

        let ratings = near.map(\.rating).sorted()
        let rating = CompatRating(score: ratings[ratings.count / 2]) ?? .unplayable
        let fpsValues = near.compactMap(\.fps).sorted()
        let fps = fpsValues.isEmpty ? nil : Int((Double(fpsValues.reduce(0, +)) / Double(fpsValues.count)).rounded())

        var counts: [GraphicsSettings: Int] = [:]
        var order: [GraphicsSettings] = []
        for s in near.compactMap(\.settings) {
            if counts[s] == nil { order.append(s) }
            counts[s, default: 0] += 1
        }
        let settings = order.max { counts[$0]! < counts[$1]! }

        return .estimate(CompatEstimate(
            rating: rating,
            fps: fps,
            settings: settings,
            reportCount: near.count,
            sameChipCount: near.filter { $0.chip == chip }.count,
            chip: chip
        ))
    }
}

enum MacChip {

    // "Apple M4 Pro" -> "M4 Pro". Intel Macs have no entry.
    static func parse(_ brand: String) -> String? {
        guard let match = brand.firstMatch(of: /(M[1-9]|A[1-9][0-9])( (Pro|Max|Ultra))?\b/) else { return nil }
        return String(match.output.0)
    }

    static func current() -> String? {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 else { return nil }
        return parse(buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) })
    }
}
