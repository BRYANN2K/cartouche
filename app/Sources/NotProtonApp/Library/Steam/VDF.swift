// Steam's text KeyValues files (libraryfolders.vdf, appmanifest_*.acf,
// loginusers.vdf, localconfig.vdf): quoted keys, quoted values, braces.

import Foundation

indirect enum VDF: Equatable, Sendable {
    case value(String)
    case map([(String, VDF)])

    static func == (a: VDF, b: VDF) -> Bool {
        switch (a, b) {
        case (.value(let x), .value(let y)): x == y
        case (.map(let x), .map(let y)): x.count == y.count && zip(x, y).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        default: false
        }
    }

    // Steam writes keys in varying case ("apps" and "Apps"), so lookups ignore it
    subscript(_ key: String) -> VDF? {
        guard case .map(let entries) = self else { return nil }
        return entries.first { $0.0.caseInsensitiveCompare(key) == .orderedSame }?.1
    }

    subscript(path keys: String...) -> VDF? {
        keys.reduce(Optional(self)) { $0?[$1] }
    }

    var string: String? {
        if case .value(let v) = self { return v }
        return nil
    }

    var int: Int? { string.flatMap { Int($0) } }

    var entries: [(String, VDF)] {
        if case .map(let entries) = self { return entries }
        return []
    }

    struct Malformed: Error {}

    static func parse(_ text: String) throws -> VDF {
        var reader = Reader(Array(text.unicodeScalars))
        let entries = try reader.entries(closing: false)
        return .map(entries)
    }

    static func read(_ url: URL) -> VDF? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return try? parse(text)
    }

    private struct Reader {
        let chars: [Unicode.Scalar]
        var at = 0

        init(_ chars: [Unicode.Scalar]) { self.chars = chars }

        mutating func skip() {
            while at < chars.count {
                let c = chars[at]
                if c == " " || c == "\t" || c == "\n" || c == "\r" {
                    at += 1
                } else if c == "/", at + 1 < chars.count, chars[at + 1] == "/" {
                    while at < chars.count, chars[at] != "\n" { at += 1 }
                } else {
                    return
                }
            }
        }

        mutating func token() throws -> String {
            guard at < chars.count else { throw Malformed() }
            var out = String.UnicodeScalarView()
            if chars[at] == "\"" {
                at += 1
                while at < chars.count, chars[at] != "\"" {
                    if chars[at] == "\\", at + 1 < chars.count {
                        at += 1
                        switch chars[at] {
                        case "n": out.append("\n")
                        case "t": out.append("\t")
                        default: out.append(chars[at])
                        }
                    } else {
                        out.append(chars[at])
                    }
                    at += 1
                }
                guard at < chars.count else { throw Malformed() }
                at += 1
            } else {
                while at < chars.count, !" \t\r\n{}\"".unicodeScalars.contains(chars[at]) {
                    out.append(chars[at])
                    at += 1
                }
                if out.isEmpty { throw Malformed() }
            }
            return String(out)
        }

        mutating func entries(closing: Bool) throws -> [(String, VDF)] {
            var out: [(String, VDF)] = []
            while true {
                skip()
                if at >= chars.count {
                    if closing { throw Malformed() }
                    return out
                }
                if chars[at] == "}" {
                    guard closing else { throw Malformed() }
                    at += 1
                    return out
                }
                let key = try token()
                skip()
                guard at < chars.count else { throw Malformed() }
                if chars[at] == "{" {
                    at += 1
                    out.append((key, .map(try entries(closing: true))))
                } else {
                    out.append((key, .value(try token())))
                }
            }
        }
    }
}
