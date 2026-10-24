import AppKit
import RetroArchKit
import SwiftUI

// One problem at a time from the library, the stores, the consoles or a game that quit:
// what failed, and the one step that helps when there is one.
struct ShownProblem: Equatable {
    enum Source: Equatable {
        case gameExit(UUID)
        case library
        case stores
        case consoles
    }

    enum Action: Hashable {
        case showLog
        case copySummary
        case openSettings(SettingsTab)
    }

    let source: Source
    let title: String
    var detail: String?
    var actions: [Action] = []
}

@MainActor
enum ProblemBoard {

    // A game that just quit comes first: it is the newest and names its game.
    static func pick(exit: GameExitNotice?, library: String?, stores: String?, storeFailures: [String] = [],
                     consoles: String?, consoleNeedsSettings: (String) -> Bool = { _ in false }) -> ShownProblem? {
        if let exit {
            return ShownProblem(source: .gameExit(exit.id), title: exit.title, detail: exit.detail,
                                actions: [.showLog, .copySummary])
        }
        if let library {
            return ShownProblem(source: .library, title: library, actions: needsRunner(library) ? [.openSettings(.compatibility)] : [])
        }
        // A failed download already shows its reason in Activity.
        if let stores, !storeFailures.contains(stores) {
            return ShownProblem(source: .stores, title: stores, actions: needsRunner(stores) ? [.openSettings(.compatibility)] : [])
        }
        if let consoles {
            return ShownProblem(source: .consoles, title: consoles,
                                actions: consoleNeedsSettings(consoles) ? [.openSettings(.consoles)] : [])
        }
        return nil
    }

    // Play's "Set up a runner in Settings > Compatibility to play <game>." in any language.
    static func needsRunner(_ message: String) -> Bool {
        let parts = String(localized: "Set up a runner in Settings > Compatibility to play \("\u{1}").")
            .components(separatedBy: "\u{1}")
        guard parts.count == 2 else { return false }
        return message.count > parts[0].count + parts[1].count
            && message.hasPrefix(parts[0]) && message.hasSuffix(parts[1])
    }

    // A missing BIOS or emulator is fixed in Settings > Consoles.
    static func consoleNeedsSettings(_ message: String, consoles: ConsoleCenter?) -> Bool {
        if EmulatorCatalog.all.contains(where: { ConsoleRoute.missing($0).missingText == message }) { return true }
        return consoles?.biosCache.values.contains { !$0.status.isReady && $0.status.message == message } ?? false
    }

    // Clears only the problem still shown: one that replaced it after the banner drew stays.
    static func clear(_ shown: ShownProblem, library: LibraryModel, stores: StoreCenter?, consoles: ConsoleCenter?,
                      installs: InstallCenter) {
        switch shown.source {
        case .gameExit(let id): installs.dismissExit(id)
        case .library: if library.problem == shown.title { library.problem = nil }
        case .stores: if stores?.problem == shown.title { stores?.problem = nil }
        case .consoles: if consoles?.problem == shown.title { consoles?.problem = nil }
        }
    }
}

struct ProblemBanner: View {
    let model: LibraryModel
    var installs: InstallCenter = .shared

    @Environment(StoreCenter.self) private var stores: StoreCenter?
    @Environment(ConsoleCenter.self) private var consoles: ConsoleCenter?
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var shown: ShownProblem? {
        ProblemBoard.pick(exit: installs.exitNotice, library: model.problem, stores: stores?.problem,
                          storeFailures: stores?.failures.map(\.reason) ?? [], consoles: consoles?.problem,
                          consoleNeedsSettings: { [consoles] in ProblemBoard.consoleNeedsSettings($0, consoles: consoles) })
    }

    var body: some View {
        let shown = shown
        VStack(spacing: 0) {
            if let shown {
                row(shown)
                    .transition(Motion(reduceMotion: reduceMotion).entrance)
            }
        }
        .animation(Motion(reduceMotion: reduceMotion).panel, value: shown)
    }

    private func row(_ shown: ShownProblem) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: shown.title)
                    .font(shown.detail == nil ? Font.callout : Font.headline)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if let detail = shown.detail {
                    Text(verbatim: detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(shown.actions, id: \.self) { action in
                button(action, for: shown)
            }
            Button { dismiss(shown) } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
            }
            .buttonStyle(RoundGlassStyle(size: 26))
            .help(Text("Dismiss"))
            .accessibilityLabel(Text("Dismiss"))
        }
        .padding(12)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .padding(.top, 8)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func button(_ action: ShownProblem.Action, for shown: ShownProblem) -> some View {
        switch action {
        case .showLog:
            Button("Show Log") { if let notice = notice(shown) { installs.showExitLog(gameID: notice.gameID) } }
                .buttonStyle(.pill)
        case .copySummary:
            Button("Copy Summary") {
                guard let notice = notice(shown) else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(notice.summary, forType: .string)
                AppLog.note("game exit summary copied: \(notice.name)")
            }
            .buttonStyle(.pill)
        case .openSettings(let tab):
            Button("Settings…") {
                SettingsRoute.shared.tab = tab
                openSettings()
                dismiss(shown)
            }
            .buttonStyle(.pill)
        }
    }

    private func notice(_ shown: ShownProblem) -> GameExitNotice? {
        guard case .gameExit(let id) = shown.source, let notice = installs.exitNotice, notice.id == id else { return nil }
        return notice
    }

    private func dismiss(_ shown: ShownProblem) {
        ProblemBoard.clear(shown, library: model, stores: stores, consoles: consoles, installs: installs)
    }
}
