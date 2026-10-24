import Foundation

enum JSONFile {

    // nil when the file is absent or unreadable; a file that doesn't decode moves aside
    // as <name>.bad-<timestamp> so the next save can't overwrite what the user had
    static func load<T: Decodable>(_ type: T.Type, from file: URL, now: Date = Date()) -> T? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            quarantine(file, now: now)
            return nil
        }
    }

    @discardableResult
    static func quarantine(_ file: URL, now: Date = Date()) -> URL? {
        let fm = FileManager.default
        let stamp = Int(now.timeIntervalSince1970)
        var target = file.deletingLastPathComponent().appending(path: "\(file.lastPathComponent).bad-\(stamp)")
        var n = 1
        while fm.fileExists(atPath: target.path(percentEncoded: false)) {
            target = file.deletingLastPathComponent().appending(path: "\(file.lastPathComponent).bad-\(stamp)-\(n)")
            n += 1
        }
        do {
            try fm.moveItem(at: file, to: target)
            return target
        } catch {
            return nil
        }
    }
}

// Decodes to nil instead of failing the enclosing collection
struct Lenient<T: Decodable>: Decodable {
    let value: T?

    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

extension KeyedDecodingContainer {
    // Missing key, wrong type or unknown enum raw value all read as nil
    func lenient<T: Decodable>(_ type: T.Type, forKey key: Key) -> T? {
        (try? decodeIfPresent(T.self, forKey: key)) ?? nil
    }
}
