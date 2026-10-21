
import Foundation
import SQLite3

struct StoredSession: Equatable, Sendable, Identifiable {
    enum Measurement: String, Sendable {
        case on
        case refused
    }

    var id: Int64 = 0
    var appID: Int
    var setup: PlaySetup
    var runnerName: String
    // The game's Cartouche variables (D3DM_, DXMT_, DXVK_, MTL_, ROSETTA_)
    var settings: [String: String] = [:]
    var started: Date
    var ended: Date
    var measurement: Measurement
    var measured = PlayStats.Measured()

    var duration: TimeInterval { max(0, ended.timeIntervalSince(started)) }
}

enum PerformanceIncoming {
    static let folderName = "incoming"
    static let sessionFile = "session"
    static let abandonedAfter: TimeInterval = 15 * 60

    struct Folder: Equatable, Sendable {
        let session: StoredSession
        let samples: [FrameSample]
    }

    enum Reading: Equatable, Sendable {
        case ready(Folder)
        case running
        case invalid
    }

    static func read(_ folder: URL, now: Date) -> Reading {
        let files = FileManager.default
        guard let text = try? String(contentsOf: folder.appending(path: sessionFile), encoding: .utf8) else {
            return age(of: folder, now: now) > abandonedAfter ? .invalid : .running
        }
        var keys: [String: String] = [:]
        var settings: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]), value = String(line[line.index(after: eq)...])
            if key == "setting", let inner = value.firstIndex(of: "=") {
                settings[String(value[..<inner])] = String(value[value.index(after: inner)...])
            } else if keys[key] == nil {
                keys[key] = value
            }
        }
        guard let appID = keys["app_id"].flatMap(Int.init), appID > 0,
              let started = keys["started"].flatMap(TimeInterval.init) else { return .invalid }
        // A launch folder written before the script recorded the setup still migrates in
        let runner = keys["runner"].flatMap { $0.isEmpty ? nil : $0 } ?? PlaySetup.unknownRunnerID

        let sampleFiles = ((try? files.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("samples-") }
        let samples = sampleFiles
            .map { FrameSample.parse((try? String(contentsOf: $0, encoding: .utf8)) ?? "") }
            .max { $0.reduce(0) { $0 + $1.frames } < $1.reduce(0) { $0 + $1.frames } } ?? []

        let ended: TimeInterval
        if let end = keys["ended"].flatMap(TimeInterval.init) {
            ended = end
        } else if age(of: folder, now: now) > abandonedAfter {
            ended = samples.last.map { TimeInterval($0.time) } ?? started
        } else {
            return .running
        }
        let session = StoredSession(
            appID: appID,
            setup: PlaySetup(runnerID: runner,
                             translation: keys["flavor"] == "fex" ? .fex : .rosetta,
                             backend: keys["backend"].flatMap(GraphicsBackend.init(rawValue:))),
            runnerName: keys["display"].flatMap { $0.isEmpty ? nil : $0 } ?? runner,
            settings: settings,
            started: Date(timeIntervalSince1970: started),
            ended: Date(timeIntervalSince1970: max(started, ended)),
            measurement: keys["measure"] == "refused" ? .refused : .on,
            measured: PlayStats.measure(samples))
        return .ready(Folder(session: session, samples: samples))
    }

    private static func age(of folder: URL, now: Date) -> TimeInterval {
        let files = FileManager.default
        let entries = [folder] + ((try? files.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
        let newest = entries.compactMap {
            (try? files.attributesOfItem(atPath: $0.path(percentEncoded: false)))?[.modificationDate] as? Date
        }.max() ?? .distantPast
        return now.timeIntervalSince(newest)
    }
}

struct PerformanceStore: Sendable {

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    let folder: URL

    init(folder: URL = SupportPaths.performance) {
        self.folder = folder
    }

    var database: URL { folder.appending(path: "sessions.sqlite") }
    var incoming: URL { folder.appending(path: PerformanceIncoming.folderName) }

    static let schemaVersion = 2

    static let schema = """
        CREATE TABLE IF NOT EXISTS sessions (
          id INTEGER PRIMARY KEY,
          folder TEXT NOT NULL UNIQUE,
          app_id INTEGER NOT NULL,
          runner TEXT NOT NULL,
          translation TEXT NOT NULL,
          backend TEXT,
          runner_name TEXT NOT NULL,
          settings TEXT NOT NULL,
          started REAL NOT NULL,
          ended REAL NOT NULL,
          measurement TEXT NOT NULL,
          measured_seconds INTEGER NOT NULL,
          frames INTEGER NOT NULL,
          average REAL,
          low1 REAL,
          histogram TEXT NOT NULL,
          width INTEGER,
          height INTEGER
        );
        CREATE INDEX IF NOT EXISTS sessions_app ON sessions(app_id);
        CREATE TABLE IF NOT EXISTS samples (
          session INTEGER NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
          time INTEGER NOT NULL,
          frames INTEGER NOT NULL,
          frontmost INTEGER NOT NULL,
          counted INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS samples_session ON samples(session);
        """

    @discardableResult
    func ingest(now: Date = Date()) throws -> [StoredSession] {
        let files = FileManager.default
        let folders = ((try? files.contentsOfDirectory(at: incoming, includingPropertiesForKeys: nil)) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !folders.isEmpty else { return [] }
        let db = try Database(database)
        var added: [StoredSession] = []
        for folder in folders {
            switch PerformanceIncoming.read(folder, now: now) {
            case .running:
                continue
            case .invalid:
                try? files.removeItem(at: folder)
            case .ready(let read):
                do {
                    if let session = try insert(read, name: folder.lastPathComponent, into: db) { added.append(session) }
                    // Read once: the row exists now, even when this folder was read before a crash
                    try? files.removeItem(at: folder)
                } catch {
                    // One bad folder cannot stop the rest; it is kept in incoming/failed
                    AppLog.note("session folder \(folder.lastPathComponent) not ingested: \(error.localizedDescription)")
                    let failed = incoming.appending(path: "failed")
                    try? files.createDirectory(at: failed, withIntermediateDirectories: true)
                    try? files.moveItem(at: folder, to: failed.appending(path: folder.lastPathComponent))
                }
            }
        }
        return added
    }

    var hasIncomingSessions: Bool {
        ((try? FileManager.default.contentsOfDirectory(atPath: incoming.path(percentEncoded: false))) ?? [])
            .contains { !$0.hasPrefix(".") && $0 != "failed" }
    }

    private func insert(_ read: PerformanceIncoming.Folder, name: String, into db: Database) throws -> StoredSession? {
        var s = read.session
        try db.execute("BEGIN")
        do {
            let settings = String(decoding: try JSONEncoder.sorted.encode(s.settings), as: UTF8.self)
            let histogram = s.measured.histogram.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }
                .joined(separator: ",")
            let inserted = try db.run("""
                INSERT OR IGNORE INTO sessions (folder, app_id, runner, translation, backend, runner_name, settings,
                  started, ended, measurement, measured_seconds, frames, average, low1, histogram, width, height)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, [.text(name), .int(Int64(s.appID)), .text(s.setup.runnerID), .text(s.setup.translation.rawValue),
                      s.setup.backend.map { .text($0.rawValue) } ?? .null, .text(s.runnerName), .text(settings),
                      .real(s.started.timeIntervalSince1970), .real(s.ended.timeIntervalSince1970),
                      .text(s.measurement.rawValue), .int(Int64(s.measured.seconds)), .int(Int64(s.measured.frames)),
                      s.measured.average.map { .real($0) } ?? .null, s.measured.low1.map { .real($0) } ?? .null,
                      .text(histogram), s.measured.width.map { .int(Int64($0)) } ?? .null,
                      s.measured.height.map { .int(Int64($0)) } ?? .null])
            guard inserted > 0 else {
                try db.execute("ROLLBACK")
                return nil
            }
            let id = db.lastInsertID
            s.id = id
            for (sample, counts) in zip(read.samples, PlayStats.counted(read.samples)) {
                try db.run("INSERT INTO samples (session, time, frames, frontmost, counted) VALUES (?, ?, ?, ?, ?)",
                           [.int(id), .int(Int64(sample.time)), .int(Int64(sample.frames)),
                            .int(sample.frontmost ? 1 : 0), .int(counts ? 1 : 0)])
            }
            try db.execute("COMMIT")
            return s
        } catch {
            try? db.execute("ROLLBACK")
            throw error
        }
    }

    func sessions(appID: Int? = nil) throws -> [StoredSession] {
        guard FileManager.default.fileExists(atPath: database.path(percentEncoded: false)) else { return [] }
        let db = try Database(database)
        let rows = try db.query("""
            SELECT id, app_id, runner, translation, backend, runner_name, settings, started, ended, measurement,
              measured_seconds, frames, histogram, width, height
            FROM sessions \(appID == nil ? "" : "WHERE app_id = ?") ORDER BY started, id
            """, appID.map { [.int(Int64($0))] } ?? [])
        return rows.compactMap { row in
            guard case .int(let id) = row[0], case .int(let app) = row[1], case .text(let runner) = row[2],
                  case .text(let translation) = row[3], case .text(let name) = row[5], case .text(let settings) = row[6],
                  case .real(let started) = row[7], case .real(let ended) = row[8], case .text(let measurement) = row[9],
                  case .int(let seconds) = row[10], case .int(let frames) = row[11], case .text(let histogram) = row[12]
            else { return nil }
            var measured = PlayStats.Measured(seconds: Int(seconds), frames: Int(frames))
            for pair in histogram.split(separator: ",") {
                let parts = pair.split(separator: ":").compactMap { Int($0) }
                if parts.count == 2 { measured.histogram[parts[0]] = parts[1] }
            }
            if case .int(let w) = row[13] { measured.width = Int(w) }
            if case .int(let h) = row[14] { measured.height = Int(h) }
            var backend: GraphicsBackend?
            if case .text(let raw) = row[4] { backend = GraphicsBackend(rawValue: raw) }
            return StoredSession(
                id: id, appID: Int(app),
                setup: PlaySetup(runnerID: runner, translation: GameSetupChoice.Translation(rawValue: translation) ?? .rosetta,
                                 backend: backend),
                runnerName: name,
                settings: (try? JSONDecoder().decode([String: String].self, from: Data(settings.utf8))) ?? [:],
                started: Date(timeIntervalSince1970: started), ended: Date(timeIntervalSince1970: ended),
                measurement: StoredSession.Measurement(rawValue: measurement) ?? .on,
                measured: measured)
        }
    }

    func samples(session: Int64) throws -> [(sample: FrameSample, counted: Bool)] {
        let db = try Database(database)
        return try db.query("SELECT time, frames, frontmost, counted FROM samples WHERE session = ? ORDER BY time",
                            [.int(session)]).compactMap { row in
            guard case .int(let t) = row[0], case .int(let f) = row[1], case .int(let front) = row[2],
                  case .int(let counted) = row[3] else { return nil }
            return (FrameSample(time: Int(t), frames: Int(f), frontmost: front != 0), counted != 0)
        }
    }

    func add(_ session: StoredSession, folder name: String) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let db = try Database(database)
        _ = try insert(PerformanceIncoming.Folder(session: session, samples: []), name: name, into: db)
    }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

final class Database {

    enum Value: Equatable {
        case null
        case int(Int64)
        case real(Double)
        case text(String)
    }

    private var handle: OpaquePointer?

    init(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path(percentEncoded: false), &handle,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "out of memory"
            sqlite3_close(handle)
            throw PerformanceStore.Failure(description: message)
        }
        sqlite3_busy_timeout(handle, 2000)
        try execute("PRAGMA foreign_keys = ON")
        try execute(PerformanceStore.schema)
        try migrate()
        try execute("PRAGMA user_version = \(PerformanceStore.schemaVersion)")
    }

    deinit { sqlite3_close(handle) }

    var lastInsertID: Int64 { sqlite3_last_insert_rowid(handle) }

    // A database written before sessions carried the setup gets the missing columns and
    // fills them from what it has: the display name for the runner, Rosetta for translation
    private func migrate() throws {
        var version: Int64 = 0
        if case .int(let v)? = try query("PRAGMA user_version").first?.first { version = v }
        guard version < PerformanceStore.schemaVersion else { return }
        try addMissingColumns("sessions", [
            ("runner", "TEXT NOT NULL DEFAULT '\(PlaySetup.unknownRunnerID)'"),
            ("translation", "TEXT NOT NULL DEFAULT 'rosetta'"),
            ("backend", "TEXT"),
            ("runner_name", "TEXT NOT NULL DEFAULT ''"),
            ("settings", "TEXT NOT NULL DEFAULT '{}'"),
            ("measurement", "TEXT NOT NULL DEFAULT 'on'"),
            ("measured_seconds", "INTEGER NOT NULL DEFAULT 0"),
            ("frames", "INTEGER NOT NULL DEFAULT 0"),
            ("average", "REAL"),
            ("low1", "REAL"),
            ("histogram", "TEXT NOT NULL DEFAULT ''"),
            ("width", "INTEGER"),
            ("height", "INTEGER"),
        ])
        try execute("""
            UPDATE sessions SET runner_name = runner
            WHERE (runner_name IS NULL OR runner_name = '') AND runner != '' AND runner != '\(PlaySetup.unknownRunnerID)'
            """)
        try execute("""
            UPDATE sessions SET runner = CASE WHEN runner_name != '' THEN runner_name ELSE '\(PlaySetup.unknownRunnerID)' END
            WHERE runner IS NULL OR runner = '' OR runner = '\(PlaySetup.unknownRunnerID)'
            """)
        try execute("UPDATE sessions SET translation = 'rosetta' WHERE translation IS NULL OR translation = ''")
        if try addMissingColumns("samples", [
            ("frontmost", "INTEGER NOT NULL DEFAULT 1"),
            ("counted", "INTEGER NOT NULL DEFAULT 0"),
        ]).contains("counted") {
            try execute("""
                UPDATE samples SET counted = CASE
                  WHEN frontmost != 0 AND frames >= \(PlayStats.loadingBelow)
                       AND time >= (SELECT MIN(time) FROM samples s WHERE s.session = samples.session)
                                   + \(PlayStats.warmUpSeconds)
                  THEN 1 ELSE 0 END
                """)
        }
    }

    @discardableResult
    private func addMissingColumns(_ table: String, _ columns: [(name: String, type: String)]) throws -> Set<String> {
        let existing = try query("PRAGMA table_info(\(table))").compactMap { row -> String? in
            if case .text(let name) = row[1] { return name }
            return nil
        }
        var added: Set<String> = []
        for column in columns where !existing.contains(column.name) {
            try execute("ALTER TABLE \(table) ADD COLUMN \(column.name) \(column.type)")
            added.insert(column.name)
        }
        return added
    }

    private var error: PerformanceStore.Failure {
        PerformanceStore.Failure(description: String(cString: sqlite3_errmsg(handle)))
    }

    func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw error }
    }

    private func prepare(_ sql: String, _ values: [Value]) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw error }
        // SQLITE_TRANSIENT: SQLite copies each text before the call returns.
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in values.enumerated() {
            let slot = Int32(index + 1)
            switch value {
            case .null: sqlite3_bind_null(statement, slot)
            case .int(let v): sqlite3_bind_int64(statement, slot, v)
            case .real(let v): sqlite3_bind_double(statement, slot, v)
            case .text(let v): sqlite3_bind_text(statement, slot, v, -1, transient)
            }
        }
        return statement
    }

    @discardableResult
    func run(_ sql: String, _ values: [Value] = []) throws -> Int {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw error }
        return Int(sqlite3_changes(handle))
    }

    func query(_ sql: String, _ values: [Value] = []) throws -> [[Value]] {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        var rows: [[Value]] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw error }
            rows.append((0..<sqlite3_column_count(statement)).map { column in
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: .int(sqlite3_column_int64(statement, column))
                case SQLITE_FLOAT: .real(sqlite3_column_double(statement, column))
                case SQLITE_TEXT: .text(String(cString: sqlite3_column_text(statement, column)))
                default: .null
                }
            })
        }
        return rows
    }
}
