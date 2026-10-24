// The nightly compat.json, per docs/schema/compat.schema.json.

import Foundation

struct CompatData: Decodable, Sendable {

    let schemaVersion: Int
    let generated: Date
    let sources: Sources
    let gpuStrength: [String: Double]
    let records: [String: CompatRecord]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", generated, sources
        case gpuStrength = "gpu_strength", records
    }

    struct Rejected: Error, CustomStringConvertible {
        let description: String
    }

    static func read(_ data: Data, schema: CompatSchema) throws -> CompatData {
        let json = data.first == 0x1f ? try Gzip.decompress(data) : data
        let tree: SchemaValue
        do {
            tree = try JSONDecoder().decode(SchemaValue.self, from: json)
        } catch {
            throw Rejected(description: "not JSON")
        }
        let problems = schema.errors(tree)
        guard problems.isEmpty else {
            throw Rejected(description: "does not match the schema: " + problems.prefix(3).joined(separator: "; "))
        }
        return try JSONDecoder().decode(CompatData.self, from: json)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        let stamp = try c.decode(String.self, forKey: .generated)
        guard let date = CompatDate.instant(stamp) else {
            throw DecodingError.dataCorruptedError(forKey: .generated, in: c, debugDescription: stamp)
        }
        generated = date
        sources = try c.decode(Sources.self, forKey: .sources)
        gpuStrength = try c.decode([String: Double].self, forKey: .gpuStrength)
        records = try c.decode([String: CompatRecord].self, forKey: .records)
    }

    func record(appID: Int) -> CompatRecord? { records[String(appID)] }
}

struct CompatSource: Decodable, Sendable, Equatable {
    let name: String
    let credit: String
    let url: String
    let license: String
    let licenseURL: String
    let attribution: String
    let fetched: String
    let status: Status
    let export: String?

    enum Status: String, Decodable, Sendable { case fresh, stale }

    enum CodingKeys: String, CodingKey {
        case name, credit, url, license, licenseURL = "license_url", attribution, fetched, status, export
    }
}

struct Sources: Decodable, Sendable {
    let applegamingwiki: CompatSource
    let protondb: CompatSource
    let areweanticheatyet: CompatSource

    var all: [CompatSource] { [applegamingwiki, protondb, areweanticheatyet] }
}

struct CompatRecord: Decodable, Sendable {
    let name: String
    let applegamingwiki: AppleGamingWikiEntry?
    let protondb: ProtonDBEntry?
    let areweanticheatyet: AntiCheatEntry?
}

enum PlayMethod: String, Codable, Sendable { case native, wine, parallels, other }

enum TranslationLayer: String, Codable, Sendable {
    case d3dmetal, dxmt, dxvk

    var label: String {
        switch self {
        case .d3dmetal: "D3DMetal"
        case .dxmt: "DXMT"
        case .dxvk: "DXVK"
        }
    }
}

enum CompatRating: String, Codable, Sendable, CaseIterable {
    case unplayable, barelyPlayable = "barely_playable", playable, good, veryGood = "very_good", excellent

    init?(score: Int) {
        guard Self.allCases.indices.contains(score) else { return nil }
        self = Self.allCases[score]
    }

    var label: String {
        switch self {
        case .unplayable: String(localized: "Unplayable")
        case .barelyPlayable: String(localized: "Barely Playable")
        case .playable: String(localized: "Playable")
        case .good: String(localized: "Good")
        case .veryGood: String(localized: "Very Good")
        case .excellent: String(localized: "Excellent")
        }
    }
}

enum GraphicsSettings: String, Codable, Sendable {
    case low, medium, high, ultra

    var label: String {
        switch self {
        case .low: String(localized: "Low")
        case .medium: String(localized: "Medium")
        case .high: String(localized: "High")
        case .ultra: String(localized: "Ultra")
        }
    }
}

struct AppleGamingWikiEntry: Decodable, Sendable {
    let fetched: String
    let page: String
    let revision: Int
    let ratings: [String: String]
}

struct ProtonDBEntry: Decodable, Sendable {
    let fetched: String
    let since: String
    let reports: Int
    let works: Int
    let onlineTried: Int
    let onlinePlayed: Int
    let verdict: Verdict

    enum Verdict: String, Decodable, Sendable {
        case runs, mixed, doesntRun = "doesnt_run"
    }

    enum CodingKeys: String, CodingKey {
        case fetched, since, reports, works, onlineTried = "online_tried", onlinePlayed = "online_played", verdict
    }
}

struct AntiCheatEntry: Decodable, Sendable {
    let fetched: String
    let status: Status
    let anticheats: [String]
    let native: Bool
    let changed: String

    enum Status: String, Decodable, Sendable {
        case supported = "Supported", running = "Running", planned = "Planned", broken = "Broken", denied = "Denied"
    }
}
