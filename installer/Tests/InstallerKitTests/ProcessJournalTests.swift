import Foundation
import Testing
@testable import InstallerKit

@Suite("Process journal")
struct ProcessJournalTests {

    private func entries(_ pairs: [(pid_t, String)]) -> [ProcessGroup.Entry] {
        pairs.map { .init(pid: $0.0, comm: $0.1, descendant: true) }
    }

    @Test("Every process seen is named with its start and end; the root's exit status is recorded")
    func lifetimes() throws {
        let file = try tempFolder([:]).appending(path: "processes.log")
        let journal = try #require(ProcessJournal(file: file))
        let t0 = Date()
        journal.record(descendants: entries([(100, "setup.exe"), (110, "setup.tmp")]), environment: nil, at: t0)
        journal.record(descendants: entries([(110, "setup.tmp"), (120, "unarc.exe")]), environment: nil, at: t0 + 1)
        journal.finish(root: 100, status: 0, at: t0 + 2)
        journal.close()

        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.contains("+ 100 setup.exe"))
        #expect(text.contains("+ 110 setup.tmp"))
        #expect(text.contains("+ 120 unarc.exe"))
        #expect(text.contains("- 100 setup.exe"))
        #expect(text.contains("= 100 setup.exe exited, status 0"))
    }

    @Test("A process still alive at the end is flagged, not silently dropped")
    func stillRunning() throws {
        let file = try tempFolder([:]).appending(path: "processes.log")
        let journal = try #require(ProcessJournal(file: file))
        journal.record(descendants: entries([(100, "setup.exe"), (130, "precomp.exe")]), environment: nil)
        journal.finish(root: 100, status: 1)
        journal.close()
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.contains("! 130 precomp.exe still running at end"))
        #expect(text.contains("= 100 setup.exe exited, status 1"))
    }

    @Test("A process found only through the prefix environment ends when a full scan drops it")
    func environmentMatch() throws {
        let file = try tempFolder([:]).appending(path: "processes.log")
        let journal = try #require(ProcessJournal(file: file))
        let env = [ProcessGroup.Entry(pid: 200, comm: "setup.tmp", descendant: false)]
        journal.record(descendants: [], environment: env)
        // A tick without an environment scan keeps it.
        journal.record(descendants: [], environment: nil)
        journal.record(descendants: [], environment: [])
        journal.finish(root: 100, status: 0)
        journal.close()
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.contains("+ 200 setup.tmp"))
        #expect(text.contains("- 200 setup.tmp"))
    }
}

@Suite("Bounded output")
struct OutputLogTests {

    @Test("Past the cap the head stays, the middle is dropped, the tail is kept and the loss is counted")
    func bounded() throws {
        let url = try tempFolder([:]).appending(path: "wine-output.log")
        let limit: Int64 = 200 * 1024
        let log = try #require(OutputLog(url: url, limit: limit))
        let head = Data("HEAD-LINE\n".utf8)
        log.feed(head)
        for i in 0..<40 {
            log.feed(Data(("middle line \(i) " + String(repeating: "x", count: 8000) + "\n").utf8))
        }
        let tail = Data("TAIL-LINE\n".utf8)
        log.feed(tail)
        log.finish()

        let size = try #require(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        #expect(Int64(size) <= limit)
        #expect(log.skipped > 0)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.hasPrefix("HEAD-LINE"))
        #expect(text.contains("bytes skipped"))
        #expect(text.hasSuffix("TAIL-LINE\n"))
    }
}
