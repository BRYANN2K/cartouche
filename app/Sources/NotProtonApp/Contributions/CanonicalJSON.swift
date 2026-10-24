// The backend signs canonical() from backend/src/util.ts: sorted keys, JSON.stringify strings and numbers.

import Foundation
import RetroArchKit

enum CanonicalJSON {

    static func parse(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }

    static func string(_ value: JSONValue) -> String {
        var out = ""
        write(value, into: &out)
        return out
    }

    static func data(_ value: JSONValue) -> Data { Data(string(value).utf8) }

    private static func write(_ value: JSONValue, into out: inout String) {
        switch value {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .number(let n): out += number(n)
        case .string(let s): out += quoted(s)
        case .array(let items):
            out += "["
            for (i, item) in items.enumerated() {
                if i > 0 { out += "," }
                write(item, into: &out)
            }
            out += "]"
        case .object(let fields):
            out += "{"
            let keys = fields.keys.sorted { Array($0.utf16).lexicographicallyPrecedes(Array($1.utf16)) }
            for (i, key) in keys.enumerated() {
                if i > 0 { out += "," }
                out += quoted(key) + ":"
                write(fields[key]!, into: &out)
            }
            out += "}"
        }
    }

    static func quoted(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    // Number.prototype.toString for finite doubles
    static func number(_ n: Double) -> String {
        guard n.isFinite else { return "null" }
        if n == 0 { return "0" }
        if n == n.rounded(), abs(n) < 1e21 { return String(Int64(n)) }
        let sign = n < 0 ? "-" : ""
        var text = "\(abs(n))"
        var exponent = 0
        if let e = text.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            exponent = Int(text[text.index(after: e)...]) ?? 0
            text = String(text[..<e])
        }
        var digits = text.replacingOccurrences(of: ".", with: "")
        var point = (text.firstIndex(of: ".").map { text.distance(from: text.startIndex, to: $0) } ?? text.count) + exponent
        while digits.hasPrefix("0") && digits.count > 1 {
            digits.removeFirst()
            point -= 1
        }
        while digits.hasSuffix("0") && digits.count > 1 { digits.removeLast() }
        let k = digits.count
        if k <= point && point <= 21 { return sign + digits + String(repeating: "0", count: point - k) }
        if 0 < point && point <= 21 {
            return sign + digits.prefix(point) + "." + digits.dropFirst(point)
        }
        if -6 < point && point <= 0 { return sign + "0." + String(repeating: "0", count: -point) + digits }
        let e = point - 1
        let mantissa = k == 1 ? digits : digits.prefix(1) + "." + digits.dropFirst()
        return sign + mantissa + "e" + (e >= 0 ? "+" : "-") + String(abs(e))
    }
}
