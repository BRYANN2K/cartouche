// Checks a compat.json against docs/schema/compat.schema.json before the app trusts it.
// Knows only the keywords that schema uses, like tools/compat/compatdata/schema.py.

import Foundation

enum SchemaValue: Decodable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([SchemaValue])
    case object([String: SchemaValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([SchemaValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: SchemaValue].self))
        }
    }

    var typeName: String {
        switch self {
        case .null: "null"
        case .bool: "boolean"
        case .number(let n): n.rounded() == n ? "integer" : "number"
        case .string: "string"
        case .array: "array"
        case .object: "object"
        }
    }

    subscript(key: String) -> SchemaValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }
}

struct CompatSchema: Sendable {

    let root: SchemaValue
    // Every "pattern" in the schema, compiled once instead of per checked string
    private let patterns: [String: NSRegularExpression]

    static let annotations: Set<String> = ["$schema", "$id", "$comment", "title", "description", "$defs"]
    static let checks: Set<String> = [
        "$ref", "type", "enum", "const", "properties", "required", "additionalProperties",
        "propertyNames", "minProperties", "items", "minItems", "minLength", "pattern",
        "minimum", "maximum", "exclusiveMinimum", "format",
    ]

    struct Unsupported: Error, CustomStringConvertible {
        let description: String
    }

    init(_ data: Data) throws {
        let root = try JSONDecoder().decode(SchemaValue.self, from: data)
        try Self.checkKeywords(root)
        self.root = root
        var names: Set<String> = []
        Self.patterns(root, into: &names)
        patterns = names.reduce(into: [:]) { out, name in
            out[name] = try? NSRegularExpression(pattern: name)
        }
    }

    // The copy bundled with the app, kept equal to docs/schema by a test
    static func bundled() throws -> CompatSchema {
        guard let url = Bundle.module.url(forResource: "compat.schema", withExtension: "json") else {
            throw Unsupported(description: "compat.schema.json is not in the app bundle")
        }
        return try CompatSchema(Data(contentsOf: url))
    }

    private static func checkKeywords(_ node: SchemaValue) throws {
        guard case .object(let schema) = node else { return }
        for (key, value) in schema {
            guard annotations.contains(key) || checks.contains(key) else {
                throw Unsupported(description: "unsupported keyword \(key)")
            }
            if key == "format", value != .string("date"), value != .string("date-time") {
                throw Unsupported(description: "unsupported format \(value)")
            }
            if key == "properties" || key == "$defs", case .object(let subs) = value {
                for sub in subs.values { try checkKeywords(sub) }
            } else if ["items", "additionalProperties", "propertyNames"].contains(key) {
                try checkKeywords(value)
            }
        }
    }

    private static func patterns(_ node: SchemaValue, into out: inout Set<String>) {
        guard case .object(let schema) = node else { return }
        for (key, value) in schema {
            if key == "pattern", case .string(let pattern) = value { out.insert(pattern) }
            if key == "properties" || key == "$defs", case .object(let subs) = value {
                for sub in subs.values { patterns(sub, into: &out) }
            } else if ["items", "additionalProperties", "propertyNames"].contains(key) {
                patterns(value, into: &out)
            }
        }
    }

    func errors(_ document: SchemaValue) -> [String] {
        var found: [String] = []
        validate(document, root, "$", &found)
        return found
    }

    private func resolve(_ ref: String) -> SchemaValue? {
        guard ref.hasPrefix("#/") else { return nil }
        var node: SchemaValue? = root
        for part in ref.dropFirst(2).split(separator: "/") {
            node = node?[String(part)]
        }
        return node
    }

    private func isType(_ value: SchemaValue, _ wanted: String) -> Bool {
        value.typeName == wanted || (wanted == "number" && value.typeName == "integer")
    }

    private func number(_ value: SchemaValue?) -> Double? {
        if case .number(let n) = value { return n }
        return nil
    }

    private func validate(_ value: SchemaValue, _ schemaNode: SchemaValue, _ path: String, _ found: inout [String]) {
        guard case .object(let schema) = schemaNode else { return }

        if case .string(let ref) = schema["$ref"] {
            if let target = resolve(ref) {
                validate(value, target, path, &found)
            } else {
                found.append("\(path): unresolved \(ref)")
            }
        }

        if let type = schema["type"] {
            let wanted: [String] = switch type {
            case .string(let one): [one]
            case .array(let many): many.compactMap { if case .string(let s) = $0 { s } else { nil } }
            default: []
            }
            if !wanted.contains(where: { isType(value, $0) }) {
                found.append("\(path): \(value.typeName) is not \(wanted.joined(separator: " or "))")
                return
            }
        }
        if case .array(let options) = schema["enum"], !options.contains(value) {
            found.append("\(path): not one of the allowed values")
        }
        if let constant = schema["const"], constant != value {
            found.append("\(path): not the required value")
        }

        switch value {
        case .number(let n):
            if let minimum = number(schema["minimum"]), n < minimum { found.append("\(path): below \(minimum)") }
            if let maximum = number(schema["maximum"]), n > maximum { found.append("\(path): above \(maximum)") }
            if let floor = number(schema["exclusiveMinimum"]), n <= floor { found.append("\(path): not above \(floor)") }
        case .string(let s):
            if let length = number(schema["minLength"]), Double(s.count) < length {
                found.append("\(path): too short")
            }
            if case .string(let pattern) = schema["pattern"],
               patterns[pattern]?.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) == nil {
                found.append("\(path): \(s) does not match \(pattern)")
            }
            if case .string(let format) = schema["format"], !Self.valid(s, format: format) {
                found.append("\(path): \(s) is not a \(format)")
            }
        case .array(let items):
            if let minimum = number(schema["minItems"]), Double(items.count) < minimum {
                found.append("\(path): too few items")
            }
            if let itemSchema = schema["items"] {
                for (index, item) in items.enumerated() {
                    validate(item, itemSchema, "\(path)[\(index)]", &found)
                }
            }
        case .object(let object):
            if case .array(let required) = schema["required"] {
                for case .string(let name) in required where object[name] == nil {
                    found.append("\(path): \(name) is missing")
                }
            }
            if let minimum = number(schema["minProperties"]), Double(object.count) < minimum {
                found.append("\(path): too few properties")
            }
            let properties: [String: SchemaValue] = if case .object(let p) = schema["properties"] { p } else { [:] }
            for (name, item) in object.sorted(by: { $0.key < $1.key }) {
                let at = "\(path).\(name)"
                if let names = schema["propertyNames"] {
                    validate(.string(name), names, "\(at) (name)", &found)
                }
                if let sub = properties[name] {
                    validate(item, sub, at, &found)
                } else if schema["additionalProperties"] == .bool(false) {
                    found.append("\(at): not allowed")
                } else if let extra = schema["additionalProperties"], case .object = extra {
                    validate(item, extra, at, &found)
                }
            }
        default:
            break
        }
    }

    static let datePattern = try! NSRegularExpression(pattern: #"^\d{4}-\d{2}-\d{2}$"#)
    static let instantPattern = try! NSRegularExpression(pattern: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$"#)

    static func valid(_ s: String, format: String) -> Bool {
        let range = NSRange(s.startIndex..., in: s)
        switch format {
        case "date":
            return datePattern.firstMatch(in: s, range: range) != nil && CompatDate.day(s) != nil
        case "date-time":
            return instantPattern.firstMatch(in: s, range: range) != nil && CompatDate.instant(s) != nil
        default:
            return false
        }
    }
}

enum CompatDate {

    static let gregorianGMT: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }()

    static func day(_ s: String) -> Date? {
        let parts = s.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        let components = DateComponents(year: parts[0], month: parts[1], day: parts[2])
        guard components.isValidDate(in: gregorianGMT) else { return nil }
        return gregorianGMT.date(from: components)
    }

    // ISO8601DateFormatter is thread-safe
    nonisolated(unsafe) static let plain = ISO8601DateFormatter()
    nonisolated(unsafe) static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func instant(_ s: String) -> Date? {
        plain.date(from: s) ?? fractional.date(from: s)
    }
}
