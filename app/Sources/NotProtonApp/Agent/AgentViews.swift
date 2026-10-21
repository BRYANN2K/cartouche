
import AppKit
import SwiftUI
import CartoucheMCP

struct AgentsSettingsView: View {
    @Bindable var model: AgentControlModel

    private static var claudeCode: String {
        let helper = MCPSocketServer.bundledHelper()
        return "claude mcp add cartouche -- '\(helper.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $model.enabled) {
                    Text("Let agents control Cartouche")
                    Text("Through MCP, for Claude and other assistants")
                }
                Picker("Access", selection: $model.level) {
                    ForEach(AgentLevel.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .disabled(!model.enabled)
            } footer: {
                Text("Standard: install, launch and change game settings. Full also runs commands inside a game’s Windows folder. Installs, deletions and program launches always ask first.")
            }
            if let approval = model.pending.first {
                Section("Waiting for You") {
                    LabeledContent {
                        HStack {
                            Button("Deny") { model.answer(approval, allow: false) }
                            Button("Allow") { model.answer(approval, allow: true) }
                                .buttonStyle(.borderedProminent)
                        }
                    } label: {
                        Text("\(approval.client) wants to \(approval.text).")
                        Text(verbatim: approval.tool).font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                LabeledContent {
                    Button("Copy") { copy(Self.claudeCode) }
                } label: {
                    Text("Claude Code")
                    Text(verbatim: Self.claudeCode).font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                }
                Toggle(isOn: $model.httpEnabled) {
                    Text("Other clients over HTTP")
                    Text(verbatim: "http://127.0.0.1:\(model.httpPort)/mcp").font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                }
                .disabled(!model.enabled)
                if model.httpEnabled {
                    LabeledContent {
                        Button("Copy") { copy(model.token) }
                    } label: {
                        Text("Bearer token")
                        Text(verbatim: model.token).font(.callout.monospaced())
                            .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    LabeledContent {
                        Button("Copy") { copy(model.clientConfiguration) }
                    } label: {
                        Text("Client configuration")
                        Text("The MCP server entry most clients take").foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Connect")
            } footer: {
                Text(footerText)
            }
            Section("Recent Agent Actions") {
                if model.actions.isEmpty {
                    Text("No agent actions yet").foregroundStyle(.secondary)
                }
                ForEach(model.actions.reversed()) { action in
                    LabeledContent {
                        if action.canUndo {
                            Button("Undo") { Task { await model.undo(action) } }
                        }
                    } label: {
                        Text(verbatim: action.tool)
                        Text(verbatim: subtitle(action)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var footerText: String {
        if model.httpEnabled, model.httpState != "running" {
            return String(localized: "HTTP could not start: \(model.httpState)")
        }
        return String(localized: "HTTP listens on 127.0.0.1 only; the helper clients run through Cartouche’s own channel.")
    }

    private func subtitle(_ action: AgentAction) -> String {
        var parts = [action.client]
        if !action.detail.isEmpty { parts.append(action.detail) }
        parts.append(Self.relative.localizedString(for: action.time, relativeTo: Date()))
        parts.append(status(action))
        return parts.joined(separator: " · ")
    }

    private func status(_ action: AgentAction) -> String {
        switch action.outcome {
        case .ok: action.undone ? String(localized: "Undone") : String(localized: "Done")
        case .refused(let why): String(localized: "Refused: \(why)")
        case .denied: String(localized: "Denied")
        case .error(let why): String(localized: "Failed: \(why)")
        }
    }

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

struct AgentApprovalSheet: View {
    let approval: AgentApproval
    let model: AgentControlModel

    var body: some View {
        VStack(spacing: 18) {
            Text("Cartouche agent request").font(.system(size: 17, weight: .bold))
            VStack(spacing: 4) {
                Text("\(approval.client) wants to \(approval.text). Allow?")
                    .multilineTextAlignment(.center)
                Text(verbatim: approval.tool).font(.callout.monospaced())
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button("Deny") { model.answer(approval, allow: false) }
                    .keyboardShortcut(.cancelAction)
                Button("Allow") { model.answer(approval, allow: true) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 380)
    }
}

extension View {
    func agentApprovals(_ model: AgentControlModel) -> some View {
        sheet(item: Binding(get: { model.pending.first }, set: { _ in })) { approval in
            AgentApprovalSheet(approval: approval, model: model)
                .interactiveDismissDisabled()
        }
    }
}
