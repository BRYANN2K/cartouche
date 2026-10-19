import Foundation

// A libretro core's .info file: what it plays and the BIOS files it can use.
// Lines are key = "value"; MD5s are in notes, as "(!) <file> (md5): <hash>".
public struct CoreInfo: Sendable, Equatable {

    public struct Firmware: Sendable, Equatable {
        public var path: String
        public var description: String
        public var optional: Bool
        public var md5: String?
    }

    public var displayName: String?
    public var systemName: String?
    public var systemID: String?
    public var extensions: [String]
    public var firmware: [Firmware]

    public init(parsing text: String) {
        var values: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            values[key] = value
        }

        var md5s: [String: String] = [:]
        for note in (values["notes"] ?? "").split(separator: "|") {
            guard let match = note.firstMatch(of: /^\s*\(!\)\s*(.+?)\s*\(md5\):\s*([0-9A-Fa-f]{32})\s*$/) else { continue }
            md5s[String(match.1)] = match.2.lowercased()
        }

        displayName = values["display_name"]
        systemName = values["systemname"]
        systemID = values["systemid"]
        extensions = (values["supported_extensions"] ?? "").split(separator: "|").map { $0.lowercased() }
        let count = Int(values["firmware_count"] ?? "") ?? 0
        firmware = (0..<count).compactMap { i in
            guard let path = values["firmware\(i)_path"], !path.isEmpty else { return nil }
            return Firmware(
                path: path,
                description: values["firmware\(i)_desc"] ?? path,
                optional: values["firmware\(i)_opt"] == "true",
                md5: md5s[path]
            )
        }
    }

    public static func load(_ url: URL) -> CoreInfo? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return CoreInfo(parsing: text)
    }
}
