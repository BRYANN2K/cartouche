import Foundation
import Testing

@testable import NotProtonApp

// Fixture .ips files: the two-JSON-line shape macOS writes, with synthetic
// /Users/tester paths — never a real user's folders.
enum IPSFixture {

    static let home = "/Users/tester"
    static let stamp = "2026-10-20-120042"

    static func meta(
        process: String = "Cartouche", bugType: String = "309"
    ) -> String {
        """
        {"app_name":"\(process)","timestamp":"2026-10-20 12:00:42.00 +0200","app_version":"1.4.0","slice_uuid":"F1","build_version":"42","platform":1,"bundleID":"dev.bryann2k.cartouche","share_with_app_devs":0,"is_first_party":0,"bug_type":"\(bugType)","os_version":"macOS 15.6.1 (24G90)","roots_installed":0,"name":"\(process)","incident_id":"INC-FIXTURE-1"}
        """
    }

    // A faulting thread that mixes an app frame, a system frame, one Cartouche
    // image under the support folder and dyld, in that order.
    static func payload(process: String = "Cartouche") -> String {
        """
        {"uptime":42000,"procRole":"Foreground","version":2,"userID":501,\
        "osVersion":{"train":"macOS 15.6.1","build":"24G90","releaseType":"User"},\
        "captureTime":"2026-10-20 12:00:41.12 +0200","incident":"INC-FIXTURE-1","pid":4301,\
        "cpuType":"ARM-64","procName":"\(process)",\
        "procPath":"/Applications/Cartouche.app/Contents/MacOS/\(process)",\
        "bundleInfo":{"CFBundleShortVersionString":"1.4.0","CFBundleVersion":"42","CFBundleIdentifier":"dev.bryann2k.cartouche"},\
        "parentProc":"launchd","parentPid":1,\
        "exception":{"codes":"0x0000000000000000, 0x0000000000000000","rawCodes":[0,0],"type":"EXC_CRASH","signal":"SIGABRT"},\
        "termination":{"flags":0,"code":6,"namespace":"SIGNAL","indicator":"Abort trap: 6","byProc":"\(process)","byPid":4301},\
        "faultingThread":2,\
        "threads":[\
        {"id":100,"frames":[{"imageOffset":100,"imageIndex":1}]},\
        {"id":101,"frames":[{"imageOffset":200,"imageIndex":1}]},\
        {"triggered":true,"id":102,"queue":"com.apple.main-thread","frames":[\
        {"imageOffset":1000,"symbol":"main","symbolLocation":900,"imageIndex":0},\
        {"imageOffset":777,"imageIndex":2},\
        {"imageOffset":2000,"symbol":"Cartouche.crash","symbolLocation":1900,"imageIndex":0},\
        {"imageOffset":3000,"symbol":"flush","symbolLocation":2900,"imageIndex":4},\
        {"imageOffset":5000,"symbol":"start","symbolLocation":4000,"imageIndex":3}]}],\
        "usedImages":[\
        {"source":"P","arch":"arm64e","base":4370000000,"size":100000,"uuid":"U0","path":"/Applications/Cartouche.app/Contents/MacOS/Cartouche","name":"Cartouche"},\
        {"source":"A","arch":"arm64e","base":6600000000,"size":50000,"uuid":"U1","path":"/usr/lib/system/libsystem_kernel.dylib","name":"libsystem_kernel.dylib"},\
        {"source":"A","arch":"arm64e","base":6610000000,"size":60000,"uuid":"U2","path":"/usr/lib/system/libsystem_c.dylib","name":"libsystem_c.dylib"},\
        {"source":"A","arch":"arm64e","base":6620000000,"size":70000,"uuid":"U3","path":"/usr/lib/dyld","name":"dyld"},\
        {"source":"P","arch":"arm64e","base":4380000000,"size":8000,"uuid":"U4","path":"\(home)/Library/Application Support/Cartouche/cartouche.dylib","name":"cartouche.dylib"}]}
        """
    }

    @discardableResult
    static func write(
        into dir: URL, process: String = "Cartouche", stamp: String = stamp,
        mtime: Date, bugType: String = "309"
    ) throws -> URL {
        let url = dir.appending(path: "\(process)-\(stamp).ips")
        try (meta(process: process, bugType: bugType) + "\n" + payload(process: process))
            .write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: mtime], ofItemAtPath: url.path(percentEncoded: false))
        return url
    }
}

@Suite("Crash reports")
struct CrashReportTests {

    private func logs(_ work: URL, appLines: Int? = nil, dylib: String? = nil) throws -> URL {
        let dir = work.appending(path: "logs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let appLines {
            let text = (0..<appLines).map { "LOG-LINE-\($0) at \(IPSFixture.home)/thing" }
                .joined(separator: "\n")
            try text.write(to: dir.appending(path: "app.log"), atomically: true, encoding: .utf8)
        }
        if let dylib {
            try dylib.write(to: dir.appending(path: "dylib.log"), atomically: true, encoding: .utf8)
        }
        return dir
    }

    @Test("Only Cartouche's own report names are listed, newest last")
    func fileMatching() throws {
        let dir = try scratchDirectory("crash-scan")
        let now = Date()
        try IPSFixture.write(into: dir, stamp: "2026-10-20-120000", mtime: now.addingTimeInterval(-10))
        let ours = try IPSFixture.write(into: dir, mtime: now)
        try IPSFixture.write(into: dir, process: "cartouche-mcp", stamp: "2026-10-20-120030", mtime: now.addingTimeInterval(-5))
        // Other apps and near-misses are never picked up
        try Data("{}".utf8).write(to: dir.appending(path: "Safari-2026-10-20-130000.ips"))
        try Data("{}".utf8).write(to: dir.appending(path: "Cartouches-2026-10-20-130000.ips"))
        try Data("{}".utf8).write(to: dir.appending(path: "Cartouche-2026-10-20-130000.ips.synced"))
        try Data("{}".utf8).write(to: dir.appending(path: "Cartouche-2026-10-20-130000.crash"))
        _ = try IPSFixture.write(into: dir, stamp: "2026-10-19-090000", mtime: now.addingTimeInterval(-3600))

        let found = CrashReports.reports(in: dir, since: now.addingTimeInterval(-60))
        #expect(found.map(\.lastPathComponent) == [
            "Cartouche-2026-10-20-120000.ips",
            "cartouche-mcp-2026-10-20-120030.ips",
            "Cartouche-2026-10-20-120042.ips",
        ])
        #expect(found.last?.resolvingSymlinksInPath() == ours.resolvingSymlinksInPath())
    }

    @Test("A report parses into identity, exception and the faulting thread's frames")
    func parse() throws {
        let work = try scratchDirectory("crash-parse")
        let logs = try logs(work, appLines: 5)
        let file = try IPSFixture.write(into: work, mtime: Date())
        let report = try #require(CrashReports.parse(file, logs: logs, home: IPSFixture.home))

        #expect(report.process == "Cartouche")
        #expect(report.pid == 4301)
        #expect(report.appVersion == "1.4.0")
        #expect(report.buildVersion == "42")
        #expect(report.systemVersion == "macOS 15.6.1 (24G90)")
        #expect(report.exception == "EXC_CRASH (SIGABRT)")
        #expect(report.termination == "SIGNAL 6 — Abort trap: 6 (by Cartouche [4301])")
        #expect(report.crashedThread == 2)
        #expect(report.queue == "com.apple.main-thread")
        #expect(report.incident == "INC-FIXTURE-1")

        #expect(report.frames.count == 5)
        #expect(report.frames.map(\.ours) == [true, false, true, true, false])
        #expect(report.frames[0].detail == "main + 100")
        #expect(report.frames[1].detail == "0x\(String(6610000000, radix: 16)) + 777")
        #expect(report.frames[3].detail == "flush + 100")
        #expect(report.frames[4].detail == "start + 1000")
        #expect(report.frames[0].address == 4370001000)
    }

    @Test("A frame whose image base plus offset overflows has no address instead of trapping")
    func overflowingAddress() throws {
        let work = try scratchDirectory("crash-overflow")
        defer { try? FileManager.default.removeItem(at: work) }
        let file = try IPSFixture.write(into: work, mtime: Date())
        let text = try String(contentsOf: file, encoding: .utf8)
            .replacingOccurrences(of: #""base":4370000000"#, with: #""base":\#(UInt64.max - 10)"#)
        try text.write(to: file, atomically: true, encoding: .utf8)
        let report = try #require(CrashReports.parse(file, logs: try logs(work), home: IPSFixture.home))
        #expect(report.frames[0].address == nil)
        #expect(report.frames[1].address == 6610000777)
    }

    @Test("The summary carries versions, the exception, app frames first, and the log tails")
    func summary() throws {
        let work = try scratchDirectory("crash-summary")
        let logs = try logs(work, appLines: 300, dylib: "dylib says hi at \(IPSFixture.home)")
        let file = try IPSFixture.write(into: work, mtime: Date())
        let report = try #require(CrashReports.parse(file, logs: logs, home: IPSFixture.home))
        let summary = report.summary

        for expected in [
            "Process: Cartouche [4301]",
            "Version: 1.4.0 (42)",
            "System: macOS 15.6.1 (24G90)",
            "Exception: EXC_CRASH (SIGABRT)",
            "Termination: SIGNAL 6 — Abort trap: 6 (by Cartouche [4301])",
            "Crashed thread 2 (com.apple.main-thread):",
            "main + 100",
            "--- app.log (last 200 lines) ---",
            "--- dylib.log (last 200 lines) ---",
            "dylib says hi at ~",
        ] {
            #expect(summary.contains(expected), "missing: \(expected)")
        }

        // App frames lead; the 200-line tail drops the first hundred lines
        #expect(summary.range(of: "main + 100")!.lowerBound < summary.range(of: "libsystem_c")!.lowerBound)
        #expect(!summary.contains("LOG-LINE-99\n"))
        #expect(summary.contains("LOG-LINE-299 at ~/thing"))

        // No real user path survives, plain or JSON-escaped
        #expect(!summary.contains(IPSFixture.home))
        #expect(!summary.contains(IPSFixture.home.replacingOccurrences(of: "/", with: "\\/")))
    }

    @Test("A hang report (bug_type other than 309) is not a crash")
    func notACrash() throws {
        let work = try scratchDirectory("crash-hang")
        let file = try IPSFixture.write(into: work, mtime: Date(), bugType: "211")
        #expect(CrashReports.parse(file, logs: work, home: IPSFixture.home) == nil)
    }

    @Test("The center prompts once per new report, across launches")
    @MainActor
    func launchFlow() async throws {
        let work = try scratchDirectory("crash-flow")
        let logs = try logs(work, appLines: 3)
        let dir = work.appending(path: "DiagnosticReports", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let scratch = ScratchDefaults()

        // A report from before the first launch is not news
        _ = try IPSFixture.write(into: dir, stamp: "2026-10-18-080000", mtime: Date().addingTimeInterval(-86400))
        let first = CrashReportCenter(defaults: scratch.defaults, reportsDir: dir, logsDir: logs,
                                      home: URL(filePath: IPSFixture.home), reveal: { _ in }, copy: { _ in })
        await first.check(now: Date())
        #expect(first.report == nil)

        // Between launches the app crashed: the next launch finds it
        _ = try IPSFixture.write(into: dir, mtime: Date())
        var revealed: [URL] = []
        var copied: [String] = []
        let second = CrashReportCenter(defaults: scratch.defaults, reportsDir: dir, logsDir: logs,
                                       home: URL(filePath: IPSFixture.home),
                                       reveal: { revealed.append($0) }, copy: { copied.append($0) })
        await second.check(now: Date())
        let found = try #require(second.report)
        #expect(found.process == "Cartouche")
        #expect(found.summary.contains("EXC_CRASH"))

        second.showReport()
        #expect(revealed == [found.file])
        #expect(second.report == nil)

        // Nothing new on the launch after that
        let third = CrashReportCenter(defaults: scratch.defaults, reportsDir: dir, logsDir: logs,
                                      home: URL(filePath: IPSFixture.home), reveal: { _ in }, copy: { _ in })
        await third.check(now: Date())
        #expect(third.report == nil)
    }

    @Test("Copy Summary hands the text over and closes the prompt")
    @MainActor
    func copySummary() async throws {
        let work = try scratchDirectory("crash-copy")
        let logs = try logs(work, appLines: 3)
        let dir = work.appending(path: "DiagnosticReports", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let scratch = ScratchDefaults()
        _ = try IPSFixture.write(into: dir, mtime: Date())

        var copied: [String] = []
        let center = CrashReportCenter(defaults: scratch.defaults, reportsDir: dir, logsDir: logs,
                                       home: URL(filePath: IPSFixture.home),
                                       reveal: { _ in }, copy: { copied.append($0) })
        // First launch records the marker, so report written after it
        await center.check(now: Date().addingTimeInterval(-60))
        #expect(center.report == nil)
        let next = CrashReportCenter(defaults: scratch.defaults, reportsDir: dir, logsDir: logs,
                                     home: URL(filePath: IPSFixture.home),
                                     reveal: { _ in }, copy: { copied.append($0) })
        await next.check(now: Date())
        try #require(next.report != nil)
        next.copySummary()
        #expect(copied.count == 1)
        #expect(copied[0].contains("EXC_CRASH (SIGABRT)"))
        #expect(next.report == nil)
    }
}

@Suite("Collect diagnostics")
struct DiagnosticsTests {

    @Test("The zip lands on the Desktop with the reports, the logs and a manifest")
    func collect() throws {
        let work = try scratchDirectory("diagnostics")
        let home = URL(filePath: IPSFixture.home)
        let reports = work.appending(path: "DiagnosticReports", directoryHint: .isDirectory)
        let logs = work.appending(path: "logs", directoryHint: .isDirectory)
        let desktop = work.appending(path: "Desktop", directoryHint: .isDirectory)
        for dir in [reports, logs, desktop] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try IPSFixture.write(into: reports, mtime: Date())
        try "app line at \(IPSFixture.home)/stuff\n".write(
            to: logs.appending(path: "app.log"), atomically: true, encoding: .utf8)
        try Data("{}".utf8).write(to: reports.appending(path: "Safari-2026-10-20-130000.ips"))

        let zip = try Diagnostics.collect(
            into: desktop, reportsFrom: reports, logsFrom: logs, home: home,
            stamp: Date(timeIntervalSince1970: 1_782_000_000))
        #expect(zip.lastPathComponent.hasPrefix("Cartouche-Diagnostics-"))
        #expect(zip.pathExtension == "zip")

        let out = work.appending(path: "unzipped", directoryHint: .isDirectory)
        try Shell.check("/usr/bin/ditto", ["-x", "-k", zip.path(percentEncoded: false), out.path(percentEncoded: false)])
        let root = out.appending(path: zip.deletingPathExtension().lastPathComponent, directoryHint: .isDirectory)

        let entries = try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        // The staged folder holds manifest.json plus reports/, logs/, summary.txt
        #expect(entries.contains { $0.lastPathComponent == "manifest.json" })
        #expect(entries.contains { $0.lastPathComponent == "reports" })
        #expect(entries.contains { $0.lastPathComponent == "logs" })
        #expect(entries.contains { $0.lastPathComponent == "summary.txt" })

        struct Probe: Decodable {
            struct File: Decodable { let path: String; let bytes: Int }
            let tool: String
            let appVersion: String
            let macOS: String
            let collected: String
            let files: [File]
        }
        let manifest = try JSONDecoder().decode(
            Probe.self,
            from: Data(contentsOf: root.appending(path: "manifest.json")))
        #expect(manifest.tool == "Cartouche")
        #expect(manifest.files.map(\.path).contains("logs/app.log"))
        #expect(manifest.files.map(\.path).contains("reports/Cartouche-\(IPSFixture.stamp).ips"))
        #expect(!manifest.files.map(\.path).contains { $0.contains("Safari") })

        let packedLog = try String(contentsOf: root.appending(path: "logs/app.log"), encoding: .utf8)
        #expect(packedLog.contains("~/stuff"))
        #expect(!packedLog.contains(IPSFixture.home))

        let summary = try String(contentsOf: root.appending(path: "summary.txt"), encoding: .utf8)
        #expect(summary.contains("EXC_CRASH (SIGABRT)"))
    }

    @Test("A second collection in the same second does not overwrite the first")
    func uniqueNames() throws {
        let work = try scratchDirectory("diagnostics-twice")
        let home = URL(filePath: IPSFixture.home)
        let desktop = work.appending(path: "Desktop", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: desktop, withIntermediateDirectories: true)
        let stamp = Date(timeIntervalSince1970: 1_782_000_000)
        let first = try Diagnostics.collect(into: desktop, reportsFrom: work, logsFrom: work, home: home, stamp: stamp)
        let second = try Diagnostics.collect(into: desktop, reportsFrom: work, logsFrom: work, home: home, stamp: stamp)
        #expect(first.lastPathComponent != second.lastPathComponent)
        #expect(FileManager.default.fileExists(atPath: first.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: second.path(percentEncoded: false)))
    }
}
