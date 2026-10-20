
import AppKit
import Foundation
import InstallerKit
import Observation

@MainActor
@Observable
final class InstallSheetModel {

    enum Step: Sendable, Equatable { case drop, analysis, review, installing, chooseExe, ready }

    enum Check: Sendable, Equatable {
        case running(Double?)
        case ok
        case warning
        case failed
    }

    struct Item: Identifiable, Equatable {
        let id: String
        let title: String
        let detail: String
        let check: Check
        var cover: Int? = nil
    }

    enum Cleanup: Equatable {
        case idle, confirming, done(Int64), failed(String)
    }

    @ObservationIgnored weak var center: InstallCenter?

    private var baseStep: Step = .drop
    private(set) var dropped: URL?
    private(set) var analysis: InstallerAnalysis?
    private(set) var readProblem: String?
    private(set) var isAnalyzing = false
    private(set) var verifyFraction: Double?
    private(set) var identification: GameIdentification?
    private(set) var index = GameIndex([])
    var search = "" { didSet { results = search.count < 2 ? [] : index.search(search, limit: 8) } }
    private(set) var results: [GameIndex.Entry] = []
    private(set) var runners: [Runner] = []
    var runnerID: String?
    var mode: InnoCommand.Mode = .guided
    private(set) var freeBytes: Int64?
    private(set) var job: InstallJob?
    var chosenExe: String?
    var showInSteam = true
    private(set) var steamOutcome: SteamShortcuts.Outcome?
    private(set) var finishProblem: String?
    var cleanup: Cleanup = .idle

    @ObservationIgnored private var analysisTask: Task<Void, Never>?
    @ObservationIgnored var cleaner = InstallerCleanup()
    @ObservationIgnored var loadRunners: @Sendable () -> [Runner] = { InstallRunners.choices(RunnerRegistry.refresh(free: .standard)) }
    @ObservationIgnored var tool: @Sendable () -> String? = { Innoextract.path() }

    var step: Step {
        guard let job else { return baseStep }
        switch job.phase {
        case .choosing: return .chooseExe
        case .ready: return .ready
        default: return .installing
        }
    }

    func reset() {
        analysisTask?.cancel()
        baseStep = .drop
        dropped = nil; analysis = nil; readProblem = nil; isAnalyzing = false; verifyFraction = nil
        identification = nil; search = ""; job = nil; chosenExe = nil; showInSteam = true
        steamOutcome = nil; finishProblem = nil; cleanup = .idle
    }

    func show(_ job: InstallJob) {
        analysisTask?.cancel()
        self.job = job
        if chosenExe == nil { chosenExe = job.candidates.first?.path }
    }

    // MARK: Analysis

    func analyze(_ url: URL) {
        analysisTask?.cancel()
        dropped = url
        baseStep = .analysis
        analysis = nil; readProblem = nil; identification = nil
        isAnalyzing = true
        verifyFraction = nil
        let tool = tool()
        analysisTask = Task { [weak self] in
            let start = Date()
            let inspected = await Task.detached { () -> Result<InstallerAnalysis, Error> in
                Result { try Analyzer.inspect(url, tool: tool) }
            }.value
            guard let self, !Task.isCancelled else { return }
            switch inspected {
            case .failure:
                readProblem = String(localized: "This folder could not be read.")
                isAnalyzing = false
                return
            case .success(var found):
                analysis = found
                await identify(found)
                guard !Task.isCancelled else { return }
                if let manifest = found.manifest {
                    found.checksums = await verify(manifest, root: found.folder)
                    guard !Task.isCancelled else { return }
                }
                found.seconds = Date().timeIntervalSince(start)
                analysis = found
            }
            freeBytes = Disk.freeBytes(at: GameFolder.installs)
            isAnalyzing = false
            verifyFraction = nil
            let load = loadRunners
            runners = await Task.detached { load() }.value
            if runnerID == nil || !runners.contains(where: { $0.id == runnerID }) { runnerID = runners.first?.id }
        }
    }

    private func verify(_ manifest: ChecksumManifest, root: URL) async -> [URL: ChecksumResult] {
        let total = max(1, manifest.entries.reduce(Int64(0)) { sum, entry in
            sum + ((try? entry.file.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map(Int64.init) ?? 0)
        })
        let counter = ByteCount()
        verifyFraction = 0
        let ticker = Task { [weak self] in
            while true {
                try? await Task.sleep(for: .milliseconds(200))
                if Task.isCancelled { return }
                self?.verifyFraction = min(1, Double(counter.value) / Double(total))
            }
        }
        let results = (try? await Checksums.verify(manifest, root: root) { counter.add($0) }) ?? [:]
        ticker.cancel()
        verifyFraction = nil
        return results
    }

    private func identify(_ found: InstallerAnalysis) async {
        let data = await center?.compat()
        index = await center?.titles.index(for: data) ?? GameIndex([])
        let product = found.scan.setup.flatMap(PEVersion.productName)
        identification = GameIdentification.identify(
            gogID: GOGInfo.id(inFileList: found.inno?.files ?? []), installerTitle: found.inno?.title,
            productName: product, folderName: found.folder.lastPathComponent, index: index
        )
    }

    func checkAgain() {
        if let dropped { analyze(dropped) }
    }

    var items: [Item] {
        guard let analysis else { return [] }
        var items: [Item] = []
        if let inno = analysis.inno {
            let version = inno.version.map { String($0.split(separator: ".").prefix(2).joined(separator: ".")) } ?? ""
            items.append(Item(id: "type", title: String(localized: "Inno Setup \(version) installer"),
                              detail: inno.heavyDecompression ? String(localized: "With heavy decompression (\(inno.decompressors.joined(separator: ", ")))") : String(localized: "Standard decompression"),
                              check: .ok))
        } else if analysis.scan.setup == nil {
            items.append(Item(id: "type", title: String(localized: "No setup.exe in this folder"),
                              detail: String(localized: "Choose the folder that holds the installer."), check: .failed))
        } else {
            items.append(Item(id: "type", title: String(localized: "Not an Inno Setup installer"),
                              detail: analysis.innoProblem == .toolMissing ? String(localized: "innoextract is missing, so the installer could not be read.") : String(localized: "It runs in Guided mode only."),
                              check: .warning))
        }

        let missing = analysis.missing
        let required = missing.filter { !$0.mayBeOptional }
        if let first = required.first {
            items.append(Item(id: "parts", title: String(localized: "\(first.file) is missing"),
                              detail: String(localized: "\(analysis.scan.parts.count) parts found. Add the missing file to the folder."), check: .failed))
        } else {
            items.append(Item(id: "parts", title: String(localized: "\(analysis.scan.parts.count) parts found"),
                              detail: String(localized: "\(Self.size(analysis.scan.totalSize)) in total"), check: .ok))
        }
        for part in missing where part.mayBeOptional {
            items.append(Item(id: "optional-\(part.file)", title: String(localized: "\(part.file) is missing"),
                              detail: String(localized: "It may be optional: the checksum file says some parts are optional downloads."), check: .warning))
        }

        if analysis.manifest != nil {
            if let fraction = verifyFraction {
                items.append(Item(id: "sums", title: String(localized: "Checking files…"), detail: "", check: .running(fraction)))
            } else if let damaged = analysis.damaged.first {
                items.append(Item(id: "sums", title: String(localized: "\(damaged) is damaged"),
                                  detail: String(localized: "Download it again."), check: .failed))
            } else if analysis.verified {
                items.append(Item(id: "sums", title: String(localized: "Files are intact"),
                                  detail: String(localized: "Checksums match"), check: .ok))
            }
        }

        if let id = identification {
            if let match = id.match {
                items.append(Item(id: "game", title: String(localized: "Identified as \(match.name)"),
                                  detail: String(localized: "Matched in the compatibility data"), check: .ok, cover: match.appID))
            } else {
                items.append(Item(id: "game", title: id.name, detail: String(localized: "Not found in the compatibility data. You can pick the game in the next step."), check: .warning))
            }
        }

        let need = analysis.space.total
        if let free = freeBytes {
            items.append(Item(id: "space", title: free >= need ? String(localized: "Enough space") : String(localized: "Space may run short"),
                              detail: String(localized: "About \(Self.size(need)) needed, \(Self.size(free)) free"),
                              check: free >= need ? .ok : .warning))
        }
        return items
    }

    var canContinue: Bool { !isAnalyzing && analysis?.canInstall == true }
    var hasBlockingProblem: Bool { !isAnalyzing && (readProblem != nil || analysis?.canInstall == false) }

    func toReview() { if canContinue { baseStep = .review } }

    func back() {
        switch baseStep {
        case .review: baseStep = .analysis
        case .analysis: reset()
        default: break
        }
    }

    // MARK: Review

    var gameName: String { identification?.name ?? analysis?.name ?? "" }
    var appID: Int? { identification?.match?.appID }

    func pick(_ entry: GameIndex.Entry) {
        identification = identification?.corrected(to: entry)
            ?? GameIdentification(name: entry.name, source: .user, match: entry)
        search = ""
    }

    var installDir: String { InstallInputs(runnerID: "", gameName: gameName).installDir }

    var canInstall: Bool { analysis?.canInstall == true && runnerID != nil }

    func install() {
        guard let analysis, let setup = analysis.scan.setup, let runnerID, canInstall else { return }
        let inno = analysis.inno
        let language = inno?.languages.first { $0.lowercased().hasPrefix("en") } ?? inno?.languages.first
        let files = [setup] + analysis.scan.parts.map(\.url) + (analysis.manifest.map { [$0.source] } ?? [])
        let setupSize = (try? setup.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map(Int64.init) ?? 0
        let request = InstallRequest(
            setup: setup, source: analysis.folder, name: gameName, appID: appID, gogID: identification?.gogID,
            expectedBytes: analysis.space.installed, installerBytes: analysis.scan.totalSize + setupSize,
            installerFiles: files, manifest: analysis.manifest
        )
        let job = InstallJob(request: request, inputs: InstallInputs(runnerID: runnerID, gameName: gameName, mode: mode, language: language))
        self.job = job
        center?.enqueue(job)
    }

    // MARK: Install

    func stop() {
        guard let job else { return }
        center?.stop(job)
    }

    func retry(_ fix: RetryFix) {
        guard let job else { return }
        center?.retry(job, with: fix)
    }

    var fixes: [RetryFix] {
        guard let job, let center else { return [] }
        return job.availableFixes(runners: runners.isEmpty ? center.engine.runnerIDs() : runners.map(\.id))
    }

    func showInstallerWindow() {
        guard let members = job?.run?.group.members() else { return }
        for pid in members {
            NSRunningApplication(processIdentifier: pid)?.activate()
        }
    }

    // MARK: Exe and result

    func confirmExe() {
        guard let job, let path = chosenExe ?? job.candidates.first?.path, let center else { return }
        do {
            steamOutcome = try center.finish(job, exe: URL(filePath: path), showInSteam: showInSteam)
            finishProblem = nil
        } catch {
            finishProblem = error.localizedDescription
        }
    }

    func requestCleanup() { cleanup = .confirming }

    func confirmCleanup() {
        guard let request = job?.request else { return }
        do {
            try cleaner.run(files: request.installerFiles, folder: request.source)
            cleanup = .done(request.installerBytes)
        } catch {
            cleanup = .failed(error.localizedDescription)
        }
    }

    func close() {
        guard let center else { return }
        if let job, job.phase == .ready || job.phase == .stopped {
            center.forget(job)
            reset()
        } else if job == nil || job?.phase == .failed {
            // A failed job stays listed for a retry, but the next Add Games starts fresh
            reset()
        }
        center.isSheetPresented = false
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .binary)
    }
}

final class ByteCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count: Int64 = 0
    var value: Int64 { lock.withLock { count } }
    func add(_ n: Int64) { lock.withLock { count += n } }
}
