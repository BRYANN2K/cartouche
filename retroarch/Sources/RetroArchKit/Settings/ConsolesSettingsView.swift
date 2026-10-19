import AppKit
import SwiftUI

// RetroArch's source, for the GPL-3.0 notice at the bottom of the pane
public enum RetroArchSource {
    public static let repository = URL(string: "https://github.com/libretro/RetroArch")!
}

// The Consoles pane of Settings. The app's Settings window hosts it.
public struct ConsolesSettingsView: View {

    @Bindable var model: ConsolesSettingsModel
    // Achievements, iCloud Drive, translation and netplay name (P14)
    var extras: ConsoleExtras?
    // The standalone emulators found and each console's choice (P16)
    var emulators: EmulatorShelf?
    // Picks a RetroArch.app; the app may hand in its own panel
    var chooseApp: @MainActor () -> URL?

    public init(model: ConsolesSettingsModel, extras: ConsoleExtras? = nil, emulators: EmulatorShelf? = nil,
                chooseApp: @escaping @MainActor () -> URL? = ConsolesSettingsView.openPanel) {
        self.model = model
        self.extras = extras
        self.emulators = emulators
        self.chooseApp = chooseApp
    }

    public var body: some View {
        Form {
            Section {
                Picker(selection: Binding(get: { model.choice }, set: { choice in Task { await model.select(choice) } })) {
                    ForEach(model.choices, id: \.self) { choice in
                        Text(ConsolesSettingsModel.title(choice)).tag(choice)
                    }
                } label: {
                    Text("RetroArch", bundle: .module)
                }
                .disabled(model.working)
                HStack {
                    Text(model.buildText)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        if let app = chooseApp() { Task { await model.chooseOwnCopy(app) } }
                    } label: {
                        Text("Use Your Own Copy…", bundle: .module)
                    }
                    .disabled(model.working)
                }
                // Only what a build that answered cannot do is listed
                if model.capabilities != nil {
                    ForEach(model.features.filter { !$0.available }) { row in
                        LabeledContent(row.title, value: row.note ?? "")
                    }
                }
            }

            Section {
                ForEach(model.consoles) { row in
                    ConsoleRowView(row: row, model: model)
                    if let emulators { ConsoleEmulatorPicker(console: row.console, emulators: emulators) }
                }
                Menu {
                    ForEach(model.addable) { console in
                        Button(console.name) { Task { await model.add(console) } }
                    }
                } label: {
                    Text("Add Console", bundle: .module)
                }
                .disabled(model.working || model.addable.isEmpty)
            } header: {
                Text("Consoles", bundle: .module)
            } footer: {
                if let problem = model.problem {
                    Text(problem).foregroundStyle(.red)
                }
            }

            if let emulators { StandaloneEmulatorsSection(emulators: emulators) }
            if let extras { ConsoleExtrasSections(extras: extras) }

            Section {
                HStack {
                    Text("RetroArch is free software under the GPL-3.0, built by Cartouche from its source code.", bundle: .module)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Link(destination: RetroArchSource.repository) {
                        Text("Source Code", bundle: .module)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task {
            await model.refresh()
            await emulators?.refresh()
        }
    }

    @MainActor
    public static func openPanel() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.message = String(localized: "Choose your RetroArch app.", bundle: .module)
        return panel.runModal() == .OK ? panel.url : nil
    }
}

private struct ConsoleRowView: View {
    let row: ConsoleRow
    let model: ConsolesSettingsModel

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.console.name)
                Text(row.coreText)
                    .foregroundStyle(.secondary)
                    .font(.callout)
                if row.bios.summary != .notNeeded {
                    Text(row.bios.message)
                        .foregroundStyle(row.bios.isReady ? Color.secondary : Color.orange)
                        .font(.callout)
                }
            }
            Spacer()
            if row.core != .verified, row.console.hasCore {
                Button {
                    Task { await model.updateCore(of: row.console) }
                } label: {
                    Text("Download Core", bundle: .module)
                }
                .disabled(model.working)
            }
            Button(role: .destructive) {
                Task { await model.remove(row.console) }
            } label: {
                Text("Remove", bundle: .module)
            }
            .disabled(model.working)
        }
    }
}
