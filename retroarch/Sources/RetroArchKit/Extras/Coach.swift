import Foundation

// An agent may read named Rich Presence values, never input while hardcore is on; names and addresses come from the game's RetroAchievements script.

// One value a Rich Presence script shows: @Stage(0xH0d6c)
public struct NamedValue: Sendable, Equatable {
    public struct Term: Sendable, Equatable {
        public enum Size: Sendable, Equatable {
            case bits8, bits16, bits24, bits32, bits16BE, bits24BE, bits32BE, lower4, upper4, bit(Int), bitCount
            var bytes: Int {
                switch self {
                case .bits8, .lower4, .upper4, .bit, .bitCount: 1
                case .bits16, .bits16BE: 2
                case .bits24, .bits24BE: 3
                case .bits32, .bits32BE: 4
                }
            }
        }

        public var address: UInt32?
        public var size: Size
        public var constant: Int
        public var bcd: Bool
        public var multiplier: Double

        func value(_ bytes: [UInt8]) -> Int {
            guard address != nil else { return constant }
            func le(_ n: Int) -> Int { (0..<n).reduce(0) { $0 | Int(bytes[$1]) << (8 * $1) } }
            func be(_ n: Int) -> Int { (0..<n).reduce(0) { $0 << 8 | Int(bytes[$1]) } }
            var raw: Int
            switch size {
            case .bits8: raw = le(1)
            case .bits16: raw = le(2)
            case .bits24: raw = le(3)
            case .bits32: raw = le(4)
            case .bits16BE: raw = be(2)
            case .bits24BE: raw = be(3)
            case .bits32BE: raw = be(4)
            case .lower4: raw = Int(bytes[0] & 0x0F)
            case .upper4: raw = Int(bytes[0] >> 4)
            case .bit(let n): raw = Int(bytes[0] >> UInt8(n)) & 1
            case .bitCount: raw = bytes[0].nonzeroBitCount
            }
            if bcd {
                var decimal = 0, scale = 1
                while raw > 0 { decimal += (raw & 0xF) * scale; raw >>= 4; scale *= 10 }
                raw = decimal
            }
            return raw
        }
    }

    public var name: String
    public var terms: [Term]
    public var lookup: [Int: String]
    public var fallback: String?

    public func text(_ value: Int) -> String { lookup[value] ?? fallback ?? String(value) }
}

public enum RichPresence {

    public static func values(in script: String) -> [NamedValue] {
        var lookups: [String: ([Int: String], String?)] = [:]
        var current: String?
        var display: [String] = []
        var inDisplay = false
        for raw in script.replacingOccurrences(of: "\r", with: "").split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.hasPrefix("//") ? "" : String(raw)
            if line.hasPrefix("Lookup:") {
                current = String(line.dropFirst("Lookup:".count))
                lookups[current!] = ([:], nil)
                inDisplay = false
            } else if line.hasPrefix("Format:") {
                current = nil
                inDisplay = false
            } else if line.hasPrefix("Display:") {
                current = nil
                inDisplay = true
            } else if inDisplay {
                display.append(line)
            } else if let name = current, let equals = line.firstIndex(of: "=") {
                let key = line[..<equals], text = String(line[line.index(after: equals)...])
                if key == "*" {
                    lookups[name]?.1 = text
                } else {
                    for value in keys(String(key)) { lookups[name]?.0[value] = text }
                }
            }
        }
        var out: [NamedValue] = []
        for line in display {
            var rest = Substring(line)
            while let at = rest.firstIndex(of: "@") {
                rest = rest[rest.index(after: at)...]
                guard let open = rest.firstIndex(of: "("), let close = rest[open...].firstIndex(of: ")") else { break }
                let name = String(rest[..<open])
                let expression = String(rest[rest.index(after: open)..<close])
                rest = rest[rest.index(after: close)...]
                guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }),
                      !out.contains(where: { $0.name == name }), let terms = terms(expression)
                else { continue }
                let lookup = lookups[name]
                out.append(NamedValue(name: name, terms: terms, lookup: lookup?.0 ?? [:], fallback: lookup?.1))
            }
        }
        return out
    }

    // "1", "0x1A", "1-3", "1,4"
    static func keys(_ text: String) -> [Int] {
        func number(_ s: Substring) -> Int? {
            let s = s.trimmingCharacters(in: .whitespaces)
            return s.lowercased().hasPrefix("0x") ? Int(s.dropFirst(2), radix: 16) : Int(s)
        }
        return text.split(separator: ",").flatMap { part -> [Int] in
            let ends = part.split(separator: "-")
            if ends.count == 2, let a = number(ends[0]), let b = number(ends[1]), a <= b, b - a < 4096 { return Array(a...b) }
            return number(part).map { [$0] } ?? []
        }
    }

    static func terms(_ expression: String) -> [NamedValue.Term]? {
        var terms: [NamedValue.Term] = []
        for part in expression.split(separator: "_") {
            var text = Substring(part)
            var sign = 1.0
            if text.count > 2, text.dropFirst().first == ":" {
                switch text.first {
                case "A", "M": break
                case "B": sign = -1
                default: return nil
                }
                text = text.dropFirst(2)
            }
            var multiplier = sign
            if let star = text.firstIndex(of: "*") {
                guard let k = Double(text[text.index(after: star)...]) else { return nil }
                multiplier *= k
                text = text[..<star]
            } else if let slash = text.firstIndex(of: "/") {
                guard let k = Double(text[text.index(after: slash)...]), k != 0 else { return nil }
                multiplier /= k
                text = text[..<slash]
            }
            var bcd = false
            if text.first == "b" { bcd = true; text = text.dropFirst() }
            guard let term = memref(text, bcd: bcd, multiplier: multiplier) else { return nil }
            terms.append(term)
        }
        return terms.isEmpty ? nil : terms
    }

    static func memref(_ text: Substring, bcd: Bool, multiplier: Double) -> NamedValue.Term? {
        guard text.lowercased().hasPrefix("0x") else {
            guard let constant = Int(text) else { return nil }
            return NamedValue.Term(address: nil, size: .bits8, constant: constant, bcd: false, multiplier: multiplier)
        }
        var rest = text.dropFirst(2)
        var size = NamedValue.Term.Size.bits16
        // No size letter is a hex digit, so a digit right after 0x is the address
        if let letter = rest.first, !letter.isHexDigit {
            switch letter.uppercased() {
            case "H": size = .bits8
            case " ": size = .bits16
            case "W": size = .bits24
            case "X": size = .bits32
            case "I": size = .bits16BE
            case "J": size = .bits24BE
            case "G": size = .bits32BE
            case "L": size = .lower4
            case "U": size = .upper4
            case "K": size = .bitCount
            case "M", "N", "O", "P", "Q", "R", "S", "T":
                size = .bit(Int(letter.uppercased().unicodeScalars.first!.value - Unicode.Scalar("M").value))
            default: return nil
            }
            rest = rest.dropFirst()
        }
        guard let address = UInt32(rest, radix: 16) else { return nil }
        return NamedValue.Term(address: address, size: size, constant: 0, bcd: bcd, multiplier: multiplier)
    }
}

// RetroAchievements addresses from 0 while READ_CORE_MEMORY takes the console's own address; regions from rcheevos' consoleinfo.c, unlisted consoles addressed as-is.
public enum AchievementsMemory {

    static let regions: [String: [(start: UInt32, end: UInt32, real: UInt32)]] = [
        "snes": [(0x000000, 0x01FFFF, 0x7E0000)],
        "gba": [(0x000000, 0x007FFF, 0x0300_0000), (0x008000, 0x047FFF, 0x0200_0000)],
        "genesis": [(0x000000, 0x00FFFF, 0xFF0000)],
        "mastersystem": [(0x000000, 0x001FFF, 0x00C000)],
        "gamegear": [(0x000000, 0x001FFF, 0x00C000)],
        "n64": [(0x000000, 0x7FFFFF, 0x8000_0000)],
        "nds": [(0x000000, 0x3FFFFF, 0x0200_0000)],
        "atari2600": [(0x000000, 0x00007F, 0x000080)],
    ]

    public static func systemAddress(_ address: UInt32, console: String) -> UInt32 {
        for region in regions[console] ?? [] where address >= region.start && address <= region.end {
            return region.real + (address - region.start)
        }
        return address
    }
}

public protocol CoachTarget: Sendable {
    func readMemory(address: Int, bytes: Int) async throws -> [UInt8]
    func press(player: Int, control: String, frames: Int) async throws -> String
}

extension RetroArchSession: CoachTarget {}

public enum CoachRefusal: Error, Equatable, LocalizedError {
    case off
    case hardcore
    case notPlaying
    case unknownValue(String)
    case unknownTool(String)

    public var errorDescription: String? {
        switch self {
        case .off: String(localized: "Coach mode is off for this game.", bundle: .module)
        case .hardcore: String(localized: "Hardcore mode is on: Cartouche sends no input to this game.", bundle: .module)
        case .notPlaying: String(localized: "No game is running.", bundle: .module)
        case .unknownValue(let name): String(localized: "This game has no value named \(name).", bundle: .module)
        case .unknownTool(let name): String(localized: "Cartouche has no tool named \(name).", bundle: .module)
        }
    }
}

public actor CoachRelay {

    public struct Tool: Sendable, Equatable {
        public var name: String
        public var description: String
        public var readOnly: Bool
    }

    public static let tools: [Tool] = [
        Tool(name: "coach_values", description: "List the game's named values and what each holds now.", readOnly: true),
        Tool(name: "coach_read", description: "Read one named value: its number and what the game shows for it.", readOnly: true),
        Tool(name: "coach_press", description: "Press RetroPad buttons for some frames. Refused in hardcore mode.", readOnly: false),
    ]

    public let console: String
    public private(set) var values: [NamedValue]
    private var target: (any CoachTarget)?
    private var enabled: Bool
    private let hardcore: @Sendable () async -> Bool

    public init(console: String, values: [NamedValue], target: (any CoachTarget)?, enabled: Bool,
                hardcore: @escaping @Sendable () async -> Bool) {
        self.console = console
        self.values = values
        self.target = target
        self.enabled = enabled
        self.hardcore = hardcore
    }

    public func setEnabled(_ on: Bool) { enabled = on }
    public func setTarget(_ target: (any CoachTarget)?) { self.target = target }

    public func read(_ name: String) async throws -> (value: Int, text: String) {
        guard enabled else { throw CoachRefusal.off }
        guard let target else { throw CoachRefusal.notPlaying }
        guard let named = values.first(where: { $0.name == name }) else { throw CoachRefusal.unknownValue(name) }
        var total = 0.0
        for term in named.terms {
            guard let address = term.address else {
                total += Double(term.constant) * term.multiplier
                continue
            }
            let system = AchievementsMemory.systemAddress(address, console: console)
            let bytes = try await target.readMemory(address: Int(system), bytes: term.size.bytes)
            guard bytes.count == term.size.bytes else { throw RetroArchSessionError.unexpectedReply("\(bytes.count) bytes") }
            total += Double(term.value(bytes)) * term.multiplier
        }
        let value = total.isFinite
            ? Int(min(max(total.rounded(.down), Double(Int.min)), Double(Int.max)))
            : 0
        return (value, named.text(value))
    }

    public func press(player: Int, control: String, frames: Int) async throws -> String {
        guard enabled else { throw CoachRefusal.off }
        // Checked here, so a request never reaches a hardcore session
        guard await !hardcore() else { throw CoachRefusal.hardcore }
        guard let target else { throw CoachRefusal.notPlaying }
        return try await target.press(player: player, control: control, frames: frames)
    }

    public func call(_ tool: String, _ arguments: [String: JSONValue]) async -> JSONValue {
        func result(_ text: String, error: Bool = false) -> JSONValue {
            .object(["content": .array([.object(["type": "text", "text": .string(text)])]), "isError": .bool(error)])
        }
        do {
            switch tool {
            case "coach_values":
                var lines: [String] = []
                for named in values {
                    let (value, text) = try await read(named.name)
                    lines.append("\(named.name)\t\(value)\t\(text)")
                }
                return result(lines.joined(separator: "\n"))
            case "coach_read":
                let name = arguments["name"]?.string ?? ""
                let (value, text) = try await read(name)
                return result("\(name)\t\(value)\t\(text)")
            case "coach_press":
                let reply = try await press(player: arguments["player"]?.int ?? 1, control: arguments["control"]?.string ?? "",
                                            frames: arguments["frames"]?.int ?? 3)
                return result(reply)
            default:
                throw CoachRefusal.unknownTool(tool)
            }
        } catch {
            return result(error.localizedDescription, error: true)
        }
    }
}
