import Foundation
import SwiftUI
import Testing

@testable import NotProtonApp

// The Runners section of Settings > Compatibility and the toolkit question sheet,
// on scratch fixtures: no real CrossOver, toolkit, runners folder or network.
@Suite("Settings > Compatibility > Runners", .serialized)
@MainActor
final class RunnersViewUITests {

    let work: URL
    let runners: URL
    let defaultsName: String
    let defaults: UserDefaults

    init() throws {
        work = try scratchDirectory("runners-view")
        runners = work.appending(path: "runners")
        defaultsName = "runners-view-\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: defaultsName))
    }

    deinit {
        try? FileManager.default.removeItem(at: work)
        UserDefaults(suiteName: defaultsName)?.removePersistentDomain(forName: defaultsName)
    }

    func model(builds: [RunnerManifest.Build], toolkits: @escaping @Sendable () -> [PortingToolkitInstall] = { [] }) -> RunnersModel {
        let bridge = work.appending(path: "bridge")
        return RunnersModel(
            runnersFolder: runners, downloads: work.appending(path: "downloads"),
            scan: { FreeRunnerScan(manifest: RunnerManifest(format: 1, revision: 1, builds: builds), toolkits: toolkits()) },
            registry: { RunnerRegistry.refresh(runners: $0, bridge: bridge, roots: [], manual: [], pins: [], fexAvailable: true, free: $1) },
            manifestFeed: nil, manifestCache: work.appending(path: "runners.json"),
            defaults: defaults
        )
    }

    func fixture() throws -> RunnerManifest.Build {
        let archive = try WineRunnerInstallerTests.archive(id: "wine-crossover-26.3.0-1", in: work)
        return try WineRunnerInstallerTests.build(id: "wine-crossover-26.3.0-1", for: archive)
    }

    // A scratch app folder holding a fixture toolkit of the given version
    func toolkitApp(_ version: String = "3.0") throws -> URL {
        let apps = work.appending(path: "Applications-\(UUID().uuidString)")
        try PortingToolkitTests.toolkit(
            at: apps.appending(path: "Game Porting Toolkit.app/Contents/Resources/wine/lib"), version: version)
        return apps
    }

    func search(applications apps: URL) -> PortingToolkitSource.Search {
        PortingToolkitSource.Search(volumes: work.appending(path: "Volumes"), applications: [apps])
    }

    func host(_ model: RunnersModel) -> UIHost {
        UIHost(Form { RunnersSection(model: model) }.formStyle(.grouped),
               size: CGSize(width: 640, height: 400))
    }

    @Test("Each row shows the title, detail, status and action the model computes")
    func rows() async throws {
        let build = try fixture()
        let apps = try toolkitApp()
        let search = self.search(applications: apps)
        let model = model(builds: [build], toolkits: { PortingToolkitSource.discover(search) })
        PortingToolkitSource.markAsked(version: "3.0", defaults)
        await model.refresh()

        let host = host(model)
        defer { host.close() }
        #expect(try await host.wait(for: "Wine CrossOver 26.3"))
        let texts = try host.texts(named: "settings-runners")
        for wanted in ["Built by Cartouche", "Not installed", "Download",
                       "Game Porting Toolkit 3.0", "Set Up", "Wine"] {
            #expect(texts.contains { $0.contains(wanted) }, "\(wanted) in \(texts)")
        }
    }

    @Test("The question sheet names the toolkit and the size a copy needs")
    func questionSheet() async throws {
        let apps = try toolkitApp()
        let search = self.search(applications: apps)
        let model = model(builds: [], toolkits: { PortingToolkitSource.discover(search) })
        await model.refresh()
        let question = try #require(model.toolkitQuestion)

        let host = UIHost(ToolkitQuestionSheet(question: question, model: model),
                          size: CGSize(width: 440, height: 240))
        defer { host.close() }
        #expect(try await host.wait(for: "Use in Place"))
        let texts = try host.texts(named: "runners-toolkit-question")
        for wanted in ["Game Porting Toolkit", "3.0", "Found in", "Copy", "Use in Place", "Cancel"] {
            #expect(texts.contains { $0.contains(wanted) }, "\(wanted) in \(texts)")
        }
        #expect(texts.contains { $0.contains("B") || $0.contains("MB") }, "copy size in \(texts)")
    }

    @Test("Copy answers the sheet and the row turns Ready")
    func questionCopy() async throws {
        let apps = try toolkitApp()
        let search = self.search(applications: apps)
        let model = model(builds: [], toolkits: { PortingToolkitSource.discover(search) })
        await model.refresh()
        // The section's .sheet(item:) presents the question the model asked
        #expect(model.toolkitQuestion != nil)

        await model.answerToolkit(.copy)
        #expect(model.rows.first { $0.kind == .portingToolkit }?.status == "Ready")
        #expect(model.toolkitQuestion == nil)

        let host = host(model)
        defer { host.close() }
        #expect(try await host.wait(for: "Game Porting Toolkit 3.0"))
        #expect(try await host.wait(for: "Ready"))
    }

    @Test("Use in Place answers the sheet and the row turns Ready")
    func questionInPlace() async throws {
        let apps = try toolkitApp()
        let search = self.search(applications: apps)
        let model = model(builds: [], toolkits: { PortingToolkitSource.discover(search) })
        await model.refresh()
        #expect(model.toolkitQuestion != nil)

        await model.answerToolkit(.inPlace)
        #expect(model.rows.first { $0.kind == .portingToolkit }?.status == "Ready")
        #expect(model.toolkitQuestion == nil)
        #expect(PortingToolkitSource.receipt(version: "3.0", runners: runners)?.inPlace != nil)

        let host = host(model)
        defer { host.close() }
        #expect(try await host.wait(for: "Game Porting Toolkit 3.0"))
        #expect(try await host.wait(for: "Ready"))
    }

    @Test("A gone in-place folder shows Damaged with Choose… and Repair")
    func missingFolder() async throws {
        let apps = try toolkitApp()
        let search = self.search(applications: apps)
        let model = model(builds: [], toolkits: { PortingToolkitSource.discover(search) })
        await model.refresh()
        await model.answerToolkit(.inPlace)
        try FileManager.default.removeItem(at: apps.appending(path: "Game Porting Toolkit.app"))
        await model.refresh()
        let damaged = try #require(model.rows.first { $0.kind == .portingToolkit })
        #expect(damaged.status == "Damaged")
        #expect(damaged.action == .repair)
        #expect(damaged.detail.contains("is gone"))

        let host = host(model)
        defer { host.close() }
        #expect(try await host.wait(for: "Damaged"))
        let texts = try host.texts(named: "settings-runners-missing")
        // The long temporary path wraps, so OCR may split a sentence across lines
        let joined = texts.joined(separator: " ")
        for wanted in ["Damaged", "is gone", "Choose", "Repair"] {
            #expect(joined.contains(wanted), "\(wanted) in \(texts)")
        }
    }

    @Test("Choose… copies a picked folder and the damaged row turns Ready")
    func missingFolderRepair() async throws {
        let apps = try toolkitApp()
        let search = self.search(applications: apps)
        let model = model(builds: [], toolkits: { PortingToolkitSource.discover(search) })
        await model.refresh()
        await model.answerToolkit(.inPlace)
        try FileManager.default.removeItem(at: apps.appending(path: "Game Porting Toolkit.app"))
        await model.refresh()
        #expect(model.rows.first { $0.kind == .portingToolkit }?.status == "Damaged")

        let otherApps = try toolkitApp()
        model.chooseToolkitFolder = { otherApps.appending(path: "Game Porting Toolkit.app") }
        await model.copyPickedToolkit()
        #expect(model.rows.first { $0.kind == .portingToolkit }?.status == "Ready")
        #expect(model.message == nil)
    }

    @Test("Without a toolkit the row reads Not found with the How to Get It link")
    func toolkitAbsent() async throws {
        let model = model(builds: [])
        await model.refresh()
        #expect(model.rows.first { $0.kind == .portingToolkit }?.status == "Not found")

        let host = host(model)
        defer { host.close() }
        #expect(try await host.wait(for: "Not found"))
        let texts = try host.texts()
        #expect(texts.contains { $0.contains("Game Porting Toolkit") })
        #expect(texts.contains { $0.contains("How to Get It") })
    }
}
