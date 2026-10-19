// The game panel's Your Play section and its Compare Setups sheet (P8)

import SwiftUI

enum YourPlayText {

    static func fps(_ value: Double?) -> String {
        value.map { String(localized: "\(Int($0.rounded())) fps") } ?? "–"
    }

    static func played(_ seconds: TimeInterval) -> String {
        let units: Set<Duration.UnitsFormatStyle.Unit> = seconds >= 3600 ? [.hours, .minutes] : [.minutes]
        return Duration.seconds(seconds.rounded()).formatted(.units(allowed: units, width: .abbreviated))
    }

    // "DXMT, Rosetta"
    static func detail(_ setup: PlaySetup) -> String {
        "\(setup.backend?.label ?? String(localized: "Default Graphics")), \(setup.translation.label)"
    }

    // The runner as Steam lists it, without the backend its tool name carries
    static func runner(_ play: SetupPlay) -> String {
        play.runnerName.components(separatedBy: " · ").first ?? play.runnerName
    }

    // "DXMT", or the runner too when two setups share a backend
    static func best(_ best: SetupPlay, among setups: [SetupPlay]) -> String {
        let label = best.setup.backend?.label ?? String(localized: "Default Graphics")
        let shared = setups.filter { $0.setup.backend == best.setup.backend }.count > 1
        return shared ? "\(runner(best)) · \(label)" : label
    }
}

struct YourPlayRows: View {
    let play: GamePlay
    let compare: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            cell(Text("Average"), YourPlayText.fps(play.average))
            cell(Text("1% low"), YourPlayText.fps(play.low1))
            cell(Text("Played"), YourPlayText.played(play.played))
        }
        if play.setups.count > 1, let best = play.best {
            Divider()
            HStack {
                Text("Best with \(YourPlayText.best(best, among: play.setups))").foregroundStyle(.secondary)
                Spacer()
                Button("Compare \(play.setups.count) Setups", action: compare).controlSize(.small)
            }
        }
        if let note = Self.note(play) {
            Text(note).font(.callout).foregroundStyle(.secondary)
        }
    }

    // Why a number is missing, when one is
    static func note(_ play: GamePlay) -> String? {
        if play.measurementRefused { return String(localized: "FPS can't be measured with this runner") }
        if play.average == nil { return String(localized: "No FPS measured yet") }
        return nil
    }

    private func cell(_ title: Text, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            title.font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct CompareSetupsSheet: View {
    let game: Game
    let play: GamePlay
    @Bindable var model: LibraryModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let current = model.resolution(for: game).setup
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Compare Setups").font(.title2.weight(.bold)).accessibilityAddTraits(.isHeader)
                Text(game.name).foregroundStyle(.secondary)
            }
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                GridRow {
                    Text("Setup")
                    Text("Average")
                    Text("1% low")
                    Text("Played")
                    Text(verbatim: "")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                Divider()
                ForEach(play.setups) { row in
                    GridRow {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: YourPlayText.runner(row))
                            Text(verbatim: YourPlayText.detail(row.setup)).font(.callout).foregroundStyle(.secondary)
                        }
                        HStack(spacing: 6) {
                            Text(YourPlayText.fps(row.average)).monospacedDigit()
                            if row.id == play.best?.id {
                                Text("Best")
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(Color.green.opacity(0.2)))
                                    .foregroundStyle(.green)
                            }
                        }
                        Text(YourPlayText.fps(row.low1)).monospacedDigit()
                        Text(YourPlayText.played(row.played)).monospacedDigit()
                        action(row, current: current)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 600)
    }

    @ViewBuilder
    private func action(_ row: SetupPlay, current: GameSetup) -> some View {
        if row.id == play.best?.id {
            if Self.matches(row.setup, current) {
                Text("In Use").foregroundStyle(.secondary)
            } else {
                Button("Use This Setup") { use(row.setup) }
                    .controlSize(.small)
                    .disabled(!model.runners.contains { $0.id == row.setup.runnerID && $0.isOffered })
            }
        } else {
            Text(verbatim: "")
        }
    }

    static func matches(_ setup: PlaySetup, _ current: GameSetup) -> Bool {
        current.version == .windows && current.runner?.id == setup.runnerID
            && current.translation == setup.translation && current.backend == setup.backend
    }

    private func use(_ setup: PlaySetup) {
        model.setSetup(Self.choice(setup, from: model.setup(for: game.id), macBuild: model.hasMacBuild(game)), for: game.id)
    }

    static func choice(_ setup: PlaySetup, from old: GameSetupChoice, macBuild: Bool) -> GameSetupChoice {
        var choice = old
        choice.runnerID = setup.runnerID
        choice.translation = setup.translation
        if let backend = setup.backend { choice.graphics = backend }
        // Sessions are measured on the Windows version only
        if macBuild { choice.version = .windows }
        return choice
    }
}
