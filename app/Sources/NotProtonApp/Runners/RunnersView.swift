// The Runners section of Settings > Compatibility: every runner RunnersModel lists —
// Wine builds to download, the user's Game Porting Toolkit to copy or use in place,
// the licensed CrossOver — with the one-time toolkit question as a sheet.

import AppKit
import SwiftUI

// The Mac this Mac is, in words performance estimates are based on
struct ThisMacSection: View {
    private let mac = PerformanceReport.Mac.current()

    var body: some View {
        Section {
            LabeledContent {
                Text(verbatim: "macOS \(mac.macOS)").foregroundStyle(.secondary)
            } label: {
                Text(verbatim: "Apple \(mac.chip)")
                Text(verbatim: "\(ProcessInfo.processInfo.processorCount)-core CPU, \(mac.memoryGB) GB")
                    .foregroundStyle(.secondary)
            }
            LabeledContent {
                Text("Detected automatically").foregroundStyle(.secondary)
            } label: {
                Text("Used for performance estimates")
            }
        } header: {
            Text("This Mac")
        }
    }
}

struct RunnersSection: View {
    let model: RunnersModel

    var body: some View {
        Section {
            if model.rows.isEmpty {
                Text("No runner found on this Mac yet").foregroundStyle(.secondary)
            }
            ForEach(model.rows) { row in
                RunnerRow(row: row, model: model)
            }
            if let message = model.message {
                Text(message).foregroundStyle(.red)
            }
        } header: {
            Text("Wine")
        }
        .task { await model.refresh() }
        .sheet(item: Binding(
            get: { model.toolkitQuestion },
            set: { if $0 == nil { model.dismissToolkitQuestion() } }
        )) { question in
            ToolkitQuestionSheet(question: question, model: model)
        }
    }
}

private struct RunnerRow: View {
    let row: RunnersModel.Row
    let model: RunnersModel

    // A spinner while a build downloads or a toolkit copies: the state stays
    // available or damaged while the model is busy with it
    private var working: Bool {
        if case .installing = row.state { return true }
        return row.action == .none && row.kind != .crossOver && (row.state == .available || damaged)
    }

    private var damaged: Bool {
        if case .damaged = row.state { return true }
        return false
    }

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                if working {
                    ProgressView().controlSize(.small)
                }
                Text(verbatim: row.status)
                    .foregroundStyle(damaged ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                switch row.action {
                case .download:
                    Button("Download") { Task { await model.perform(.download, on: row.id) } }
                case .setUp:
                    Button("Set Up") { Task { await model.perform(.setUp, on: row.id) } }
                case .repair:
                    if row.kind == .portingToolkit {
                        Button("Choose…") { Task { await model.copyPickedToolkit() } }
                    }
                    Button("Repair") { Task { await model.perform(.repair, on: row.id) } }
                case .none:
                    EmptyView()
                }
                if let link = row.link {
                    Button(link.title) { NSWorkspace.shared.open(link.url) }
                }
            }
        } label: {
            Text(verbatim: row.title)
            Text(verbatim: row.detail).foregroundStyle(.secondary)
        }
    }
}

// The one-time question a found toolkit asks: copy it into the runners folder,
// or read it where it is
struct ToolkitQuestionSheet: View {
    let question: RunnersModel.ToolkitQuestion
    let model: RunnersModel

    var body: some View {
        VStack(spacing: 18) {
            Text(String(localized: "Set Up Game Porting Toolkit \(question.install.version)?"))
                .font(.title2.weight(.bold))
            VStack(spacing: 4) {
                Text(String(localized: "Found in \(path)")).multilineTextAlignment(.center)
                Text(String(localized: "A copy needs \(size) on disk and keeps working after the original is removed. Use in Place reads it where it is."))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button("Cancel", role: .cancel) { model.dismissToolkitQuestion() }
                    .keyboardShortcut(.cancelAction)
                Button("Use in Place") { Task { await model.answerToolkit(.inPlace) } }
                Button("Copy") { Task { await model.answerToolkit(.copy) } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 400)
    }

    private var path: String {
        let shown = question.install.origin.pathExtension == "app"
            ? question.install.origin.deletingLastPathComponent()
            : question.install.origin
        var path = shown.standardizedFileURL.path(percentEncoded: false)
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }

    private var size: String {
        ByteCountFormatter.string(fromByteCount: question.copySize, countStyle: .file)
    }
}

// Where the model's Choose… opens a real panel; tests hand the model a fixture URL
enum ToolkitFolderPicker {

    @MainActor
    static func choose() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Choose your Game Porting Toolkit folder or app.")
        return panel.runModal() == .OK ? panel.url : nil
    }
}
