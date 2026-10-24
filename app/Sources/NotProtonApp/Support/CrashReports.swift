// Local crash reports for the "quit unexpectedly" prompt and Collect Diagnostics.
// Cartouche only ever opens files whose name starts with one of its own process
// names; other apps' reports are never read. Nothing is uploaded.

import Foundation

// MARK: - Parsed report

struct CrashReport: Sendable, Identifiable {
    struct Frame: Sendable, Equatable {
        let index: Int
        let image: String
        let address: UInt64?
        let detail: String
        let ours: Bool
    }

    var id: URL { file }
    let file: URL
    let process: String
    let pid: Int?
    let incident: String?
    let bundleID: String?
    let appVersion: String?
    let buildVersion: String?
    let systemVersion: String?
    let timeText: String?
    let exception: String?
    let termination: String?
    let crashedThread: Int?
    let queue: String?
    let frames: [Frame]
    var summary: String
}

// MARK: - Scanning and parsing

enum CrashReports {

    // The only processes whose reports Cartouche ever opens: the app, the MCP
    // helper and the support tools it runs. File names look like
    // "Cartouche-2026-10-21-103042.ips"; other apps' reports are left alone.
    static let processNames = ["Cartouche", "cartouche-mcp", "iconmaker", "appinfo"]

    static var directory: URL {
        SupportPaths.home.appending(path: "Library/Logs/DiagnosticReports", directoryHint: .isDirectory)
    }

    // Matching .ips files written after `floor`, oldest first
    static func reports(
        in directory: URL, since floor: Date, names: [String] = processNames
    ) -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        return entries.compactMap { url -> (URL, Date)? in
            guard url.pathExtension == "ips" else { return nil }
            let stem = url.deletingPathExtension().lastPathComponent
            guard names.contains(where: { stem.hasPrefix("\($0)-") }) else { return nil }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return modified > floor ? (url, modified) : nil
        }
        .sorted { $0.1 < $1.1 }
        .map(\.0)
    }

    // The newest report that parses, or nil when nothing new is readable
    static func latest(
        in directory: URL, since floor: Date, logs: URL, home: String
    ) -> CrashReport? {
        for url in reports(in: directory, since: floor).reversed() {
            if let report = parse(url, logs: logs, home: home) { return report }
        }
        return nil
    }

    static func parse(_ url: URL, logs: URL, home: String) -> CrashReport? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return parse(data, file: url, logs: logs, home: home)
    }

    // An .ips file is one line of report metadata followed by the crash payload JSON
    static func parse(_ data: Data, file: URL, logs: URL, home: String) -> CrashReport? {
        guard let newline = data.firstIndex(of: 0x0A) else { return nil }
        let meta = try? JSONDecoder().decode(IPSMeta.self, from: Data(data.prefix(newline)))
        let payload = try? JSONDecoder().decode(IPSPayload.self, from: Data(data.suffix(from: newline + 1)))
        guard meta != nil || payload != nil else { return nil }
        // 309 is a crash; hangs and resource reports are not shown
        if let bug = meta?.bug_type, bug != "309" { return nil }

        let images = payload?.usedImages ?? []
        let threads = payload?.threads ?? []
        let faulting = payload?.faultingThread ?? threads.firstIndex(where: { $0.triggered == true })
        var crashedThread: Int?
        var queue: String?
        var frames: [CrashReport.Frame] = []
        if let faulting, threads.indices.contains(faulting) {
            crashedThread = faulting
            let thread = threads[faulting]
            queue = thread.queue ?? thread.name
            frames = (thread.frames ?? []).enumerated().map { index, frame in
                let image = frame.imageIndex.flatMap { images.indices.contains($0) ? images[$0] : nil }
                let detail: String
                if let symbol = frame.symbol {
                    detail = frame.symbolLocation.map {
                        "\(symbol) + \(frame.imageOffset > $0 ? frame.imageOffset - $0 : frame.imageOffset)"
                    } ?? symbol
                } else if let base = image?.base {
                    detail = "0x\(String(base, radix: 16)) + \(frame.imageOffset)"
                } else {
                    detail = "+ \(frame.imageOffset)"
                }
                return CrashReport.Frame(
                    index: index,
                    image: image?.name ?? image?.path.map { URL(filePath: $0).lastPathComponent } ?? "unknown",
                    // A malformed report must not trap the reader: an overflowing sum is no address
                    address: image?.base.flatMap { base in
                        let (sum, overflow) = base.addingReportingOverflow(frame.imageOffset)
                        return overflow ? nil : sum
                    },
                    detail: detail,
                    ours: isOurs(image?.name, path: image?.path))
            }
        }

        let exception = [payload?.exception?.type, payload?.exception?.signal.map { "(\($0))" }]
            .compactMap { $0 }.joined(separator: " ")

        var report = CrashReport(
            file: file,
            process: payload?.procName ?? meta?.app_name ?? meta?.name
                ?? file.deletingPathExtension().lastPathComponent,
            pid: payload?.pid,
            incident: payload?.incident ?? meta?.incident_id,
            bundleID: meta?.bundleID ?? payload?.bundleInfo?.CFBundleIdentifier,
            appVersion: meta?.app_version ?? payload?.bundleInfo?.CFBundleShortVersionString,
            buildVersion: meta?.build_version ?? payload?.bundleInfo?.CFBundleVersion,
            systemVersion: meta?.os_version ?? payload?.osVersion?.full,
            timeText: payload?.captureTime ?? meta?.timestamp,
            exception: exception.isEmpty ? nil : exception,
            termination: describe(payload?.termination),
            crashedThread: crashedThread,
            queue: queue,
            frames: frames,
            summary: "")
        report.summary = summarize(report, logs: logs, home: home)
        return report
    }

    // MARK: Summary

    static let logLines = 200
    private static let tailLimit = 512 * 1024

    // The text "Copy Summary" puts on the clipboard: identity, exception, the
    // faulting thread's top frames (ours first) and the tails of both logs.
    static func summarize(_ report: CrashReport, logs: URL, home: String) -> String {
        var out = "Cartouche crash summary\n\n"
        out += "Process: \(report.process)\(report.pid.map { " [\($0)]" } ?? "")\n"
        if let bundleID = report.bundleID { out += "Identifier: \(bundleID)\n" }
        if let version = report.appVersion {
            out += "Version: \(version)\(report.buildVersion.map { " (\($0))" } ?? "")\n"
        }
        if let system = report.systemVersion { out += "System: \(system)\n" }
        if let time = report.timeText { out += "Time: \(time)\n" }
        if let incident = report.incident { out += "Incident: \(incident)\n" }
        out += "Report: \(report.file.path(percentEncoded: false))\n"

        if report.exception != nil || report.termination != nil {
            out += "\n"
            if let exception = report.exception { out += "Exception: \(exception)\n" }
            if let termination = report.termination { out += "Termination: \(termination)\n" }
        }

        if let thread = report.crashedThread {
            out += "\nCrashed thread \(thread)\(report.queue.map { " (\($0))" } ?? ""):\n"
            // Ours first, then the rest of the top of the stack — 16 rows at most
            let ours = report.frames.filter(\.ours).prefix(10)
            let others = report.frames.filter { !$0.ours }.prefix(6)
            for frame in ours + others {
                let number = frame.index < 10 ? " \(frame.index)" : "\(frame.index)"
                let address = frame.address.map { String(format: "0x%016x", $0) } ?? "?"
                let image = frame.image.padding(toLength: 20, withPad: " ", startingAt: 0)
                out += " \(number)  \(image) \(address)  \(frame.detail)\n"
            }
        }

        for name in ["app.log", "dylib.log"] {
            out += "\n--- \(name) (last \(logLines) lines) ---\n"
            if let tail = tail(of: logs.appending(path: name), lines: logLines) {
                out += tail.isEmpty ? "(empty)\n" : (tail.hasSuffix("\n") ? tail : tail + "\n")
            } else {
                out += "(not found)\n"
            }
        }
        return redact(out, home: home)
    }

    // The last `lines` lines of a log without loading more than `tailLimit` bytes
    static func tail(of url: URL, lines: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let end = handle.seekToEndOfFile()
        guard end > 0 else { return "" }
        let start = end > UInt64(tailLimit) ? end - UInt64(tailLimit) : 0
        try? handle.seek(toOffset: start)
        var text = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
        if start > 0, let first = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: first)...]) // the cut landed mid-line
        }
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .suffix(lines).joined(separator: "\n")
    }

    // The user's home folder becomes ~, both plain and JSON-escaped
    static func redact(_ text: String, home: String) -> String {
        guard !home.isEmpty, home != "/" else { return text }
        return text
            .replacingOccurrences(of: home.replacingOccurrences(of: "/", with: "\\/"), with: "~")
            .replacingOccurrences(of: home, with: "~")
    }

    private static func isOurs(_ name: String?, path: String?) -> Bool {
        if let name, processNames.contains(name) { return true }
        guard let path else { return false }
        return path.contains("/Cartouche.app/") || path.contains("Application Support/Cartouche/")
    }

    private static func describe(_ termination: IPSPayload.Termination?) -> String? {
        guard let termination else { return nil }
        var parts: [String] = []
        if let namespace = termination.namespace {
            parts.append(termination.code.map { "\(namespace) \($0)" } ?? namespace)
        }
        if let indicator = termination.indicator {
            var text = indicator
            if let proc = termination.byProc {
                text += " (by \(proc)\(termination.byPid.map { " [\($0)]" } ?? ""))"
            }
            parts.append(text)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " — ")
    }
}

// MARK: - .ips JSON shapes (decoded loosely: every field is optional)

struct IPSMeta: Decodable {
    var app_name: String?
    var timestamp: String?
    var app_version: String?
    var build_version: String?
    var bundleID: String?
    var os_version: String?
    var name: String?
    var incident_id: String?
    var bug_type: String?
}

struct IPSPayload: Decodable {
    struct BundleInfo: Decodable {
        var CFBundleShortVersionString: String?
        var CFBundleVersion: String?
        var CFBundleIdentifier: String?
    }
    struct OSVersion: Decodable {
        var train: String?
        var build: String?
        var full: String? {
            guard let train else { return nil }
            return build.map { "\(train) (\($0))" } ?? train
        }
    }
    struct Exception: Decodable {
        var type: String?
        var signal: String?
    }
    struct Termination: Decodable {
        var namespace: String?
        var code: Int?
        var indicator: String?
        var byProc: String?
        var byPid: Int?
    }
    struct Frame: Decodable {
        var imageOffset: UInt64
        var symbol: String?
        var symbolLocation: UInt64?
        var imageIndex: Int?
    }
    struct Thread: Decodable {
        var triggered: Bool?
        var name: String?
        var queue: String?
        var frames: [Frame]?
    }
    struct Image: Decodable {
        var name: String?
        var path: String?
        var base: UInt64?
    }
    var procName: String?
    var procPath: String?
    var pid: Int?
    var incident: String?
    var captureTime: String?
    var bundleInfo: BundleInfo?
    var osVersion: OSVersion?
    var exception: Exception?
    var termination: Termination?
    var faultingThread: Int?
    var threads: [Thread]?
    var usedImages: [Image]?
}

// MARK: - Collect Diagnostics

enum Diagnostics {

    // The zip written to the Desktop: manifest.json, the summary of the newest
    // report, the matching .ips files and both logs, all with the home path as ~.
    static func collect(
        into desktop: URL,
        reportsFrom reportsDir: URL,
        logsFrom logs: URL,
        home: URL,
        stamp: Date = Date(),
        appVersion: String = AppVersion.bundled,
        reportLimit: Int = 20
    ) throws -> URL {
        let fm = FileManager.default
        let homePath = home.path(percentEncoded: false)
        let name = "Cartouche-Diagnostics-\(stampFormatter.string(from: stamp))"
        let staging = fm.temporaryDirectory.appending(path: "\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        let root = staging.appending(path: name, directoryHint: .isDirectory)

        var files: [Manifest.File] = []

        func write(_ text: String, to relative: String) throws {
            let clean = CrashReports.redact(text, home: homePath)
            let url = root.appending(path: relative)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try clean.write(to: url, atomically: true, encoding: .utf8)
            files.append(.init(path: relative, bytes: clean.utf8.count))
        }

        let reports = CrashReports.reports(in: reportsDir, since: .distantPast).suffix(reportLimit)
        for reportURL in reports {
            if let text = try? String(contentsOf: reportURL, encoding: .utf8) {
                try write(text, to: "reports/\(reportURL.lastPathComponent)")
            }
        }
        for log in ["app.log", "dylib.log"] {
            if let text = try? String(contentsOf: logs.appending(path: log), encoding: .utf8) {
                try write(text, to: "logs/\(log)")
            }
        }
        if let latest = reports.last,
           let report = CrashReports.parse(latest, logs: logs, home: homePath) {
            try write(report.summary, to: "summary.txt")
        }

        let manifest = Manifest(
            appVersion: appVersion,
            macOS: ProcessInfo.processInfo.operatingSystemVersionString,
            collected: stamp.ISO8601Format(),
            files: files.sorted { $0.path < $1.path })
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try RecordCoding.encoder.encode(manifest).write(to: root.appending(path: "manifest.json"))

        try fm.createDirectory(at: desktop, withIntermediateDirectories: true)
        var zip = desktop.appending(path: "\(name).zip")
        var attempt = 2
        while fm.fileExists(atPath: zip.path(percentEncoded: false)) {
            zip = desktop.appending(path: "\(name)-\(attempt).zip")
            attempt += 1
        }
        try Shell.check("/usr/bin/ditto", [
            "-c", "-k", "--keepParent", root.path(percentEncoded: false), zip.path(percentEncoded: false)])
        return zip
    }

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    struct Manifest: Encodable {
        struct File: Encodable { let path: String; let bytes: Int }
        let tool = "Cartouche"
        let appVersion: String
        let macOS: String
        let collected: String
        let files: [File]
    }
}
