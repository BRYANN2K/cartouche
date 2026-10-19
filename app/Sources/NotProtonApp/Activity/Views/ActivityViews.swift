import SwiftUI

private struct ActivityCenterKey: @preconcurrency EnvironmentKey {
    @MainActor static var defaultValue: ActivityCenter { .shared }
}

extension EnvironmentValues {
    var activity: ActivityCenter {
        get { self[ActivityCenterKey.self] }
        set { self[ActivityCenterKey.self] = newValue }
    }
}

extension View {
    // The activity slot at the bottom of the sidebar
    func activitySlot(_ center: ActivityCenter, library: LibraryModel) -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            ActivitySlotView(center: center, library: library)
        }
    }
}

// What is going on now, at the bottom of the sidebar. Hidden when nothing is.
struct ActivitySlotView: View {
    let center: ActivityCenter
    let library: LibraryModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let slot = center.slot
        ZStack {
            if let slot {
                card(slot)
                    .padding(10)
                    .transition(Motion(reduceMotion: reduceMotion).entrance)
            }
        }
        .animation(Motion(reduceMotion: reduceMotion).panel, value: slot.map(Self.kind))
    }

    static func kind(_ slot: ActivitySlot) -> Int {
        switch slot {
        case .playing: 0
        case .installing: 1
        case .store: 2
        case .downloads: 3
        case .update: 4
        }
    }

    @ViewBuilder
    private func card(_ slot: ActivitySlot) -> some View {
        Group {
            switch slot {
            case .playing(let game): PlayingCard(game: game) { Task { await center.quitGame() } }
            case .installing(let install): InstallingCard(install: install) { center.installs.open() }
            case .store(let activity):
                StoreInstallCard(activity: activity, stop: { center.stopStore(activity) },
                                 show: { library.reveal(gameID: activity.gameID) })
            case .downloads(let downloads):
                DownloadsCard(summary: DownloadSummary(downloads: downloads),
                              toggle: { downloads.first.map { center.togglePause($0.appID) } },
                              show: { downloads.first.map { library.reveal(gameID: $0.gameID) } })
            case .update(let update): UpdateCard(update: update)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .groupBackground(radius: 12)
    }
}

private struct SlotHeader: View {
    let label: String
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(title).font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.tail)
        }
    }
}

struct PlayingCard: View {
    let game: RunningGame
    let quit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SlotHeader(label: game.starting ? String(localized: "Starting…")
                                            : game.emulator.map { String(localized: "Playing on \($0)") }
                                            ?? (game.onRetroArch ? String(localized: "Playing on RetroArch") : String(localized: "Playing")),
                       title: game.name)
            HStack(spacing: 6) {
                Circle().fill(.green).frame(width: 6, height: 6).accessibilityHidden(true)
                if let fps = game.fps {
                    Text(verbatim: "\(fps) fps").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Button("Quit", action: quit)
                    .controlSize(.small)
                    .disabled(game.starting)
                    .help(game.emulator.map { Text("Quit \($0).") }
                          ?? (game.onRetroArch ? Text("Quit the game. RetroArch saves where you are first.") : Text("Quit \(game.name)")))
            }
        }
        .accessibilityElement(children: .contain)
    }
}

struct InstallingCard: View {
    let install: InstallActivity
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 6) {
                SlotHeader(label: String(localized: "Installing"), title: install.title)
                ActivityBar(fraction: install.fraction, color: install.stuck ? .orange : .accentColor, height: 5)
                    .accessibilityLabel(Text("Install progress"))
                if install.stuck {
                    Text("The installer seems stuck.").font(.caption).foregroundStyle(.orange)
                } else if install.waiting > 0 {
                    Text(install.waiting == 1 ? String(localized: "1 more waiting") : String(localized: "\(install.waiting) more waiting"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text("Show the install"))
    }
}

// A store client's running job: the percent ring, the game, and Stop. Store
// clients cannot pause a download, so the ring only reads; Stop ends the job.
// The card taps through to the game in the library.
struct StoreInstallCard: View {
    let activity: StoreActivity
    let stop: () -> Void
    let show: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            StoreRing(fraction: activity.fraction)
            Button(action: show) {
                VStack(alignment: .leading, spacing: 2) {
                    SlotHeader(label: activity.label, title: activity.title)
                    if activity.waiting > 0 {
                        Text(activity.waiting == 1 ? String(localized: "1 more waiting")
                                                   : String(localized: "\(activity.waiting) more waiting"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(Text("Show in the library"))
            Button("Stop", action: stop)
                .controlSize(.small)
        }
        .accessibilityElement(children: .contain)
    }
}

// The store job's ring: the track and the progress arc, the percent inside.
// Drawn like DownloadRing but not a button: store clients have no Pause.
struct StoreRing: View {
    let fraction: Double
    var size: CGFloat = 32

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.12), lineWidth: 2.6)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, fraction)))
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.5), value: fraction)
            Text(verbatim: "\(Int((fraction * 100).rounded(.down)))")
                .font(.system(size: size * 0.28, weight: .semibold).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(1.3)
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel(Text("Download progress"))
        .accessibilityValue(Text("\(Int((fraction * 100).rounded(.down)))%"))
    }
}

struct DownloadsCard: View {
    let summary: DownloadSummary
    let toggle: () -> Void
    let show: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            DownloadRing(fraction: summary.fraction, mark: summary.mark, action: toggle)
            Button(action: show) {
                VStack(alignment: .leading, spacing: 2) {
                    SlotHeader(label: summary.label, title: summary.title)
                    Text(summary.detail).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(Text("Show in the library"))
        }
    }
}

struct UpdateCard: View {
    let update: UpdateActivity

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SlotHeader(label: String(localized: "Update available"), title: update.title)
            Text(update.kind).font(.caption).foregroundStyle(.secondary)
        }
    }
}

// A thin progress bar, as the mockup draws it. NSProgressIndicator animates every
// change on a thread of its own, which the slot's once-a-second updates do not need.
struct ActivityBar: View {
    let fraction: Double
    var color: Color = .accentColor
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule().fill(color).frame(width: proxy.size.width * min(1, max(0, fraction)))
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityValue(Text("\(Int((fraction * 100).rounded(.down)))%"))
    }
}

// The App Store's download ring: the track, the progress arc, and a mark in the
// middle for the state. Clicking pauses a download, or resumes a paused one.
struct DownloadRing: View {
    let fraction: Double
    let mark: DownloadSummary.Mark
    var size: CGFloat = 32
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.12), lineWidth: 2.6)
                Circle()
                    .trim(from: 0, to: max(0.001, min(1, fraction)))
                    .stroke(barColor, style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.5), value: fraction)
                markView
            }
            .padding(1.3)
            .frame(width: size, height: size)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .disabled(mark == .failed)
        .help(Text(helpText))
        .accessibilityLabel(Text(helpText))
        .accessibilityValue(Text("\(Int((fraction * 100).rounded(.down)))%"))
    }

    private var helpText: String {
        switch mark {
        case .downloading: String(localized: "Pause Download")
        case .paused: String(localized: "Resume Download")
        case .failed: String(localized: "Download failed")
        }
    }

    private var barColor: Color {
        switch mark {
        case .downloading: .accentColor
        case .paused: Color.secondary.opacity(0.6)
        case .failed: .red
        }
    }

    @ViewBuilder
    private var markView: some View {
        switch mark {
        case .downloading:
            RoundedRectangle(cornerRadius: 1.5 * size / 32)
                .fill(hovering ? Color.primary : Color.accentColor)
                .frame(width: 7 * size / 32, height: 7 * size / 32)
        case .paused:
            HStack(spacing: 2.4 * size / 32) {
                Capsule().frame(width: 2.6 * size / 32, height: 8 * size / 32)
                Capsule().frame(width: 2.6 * size / 32, height: 8 * size / 32)
            }
            .foregroundStyle(.primary)
        case .failed:
            Image(systemName: "exclamationmark")
                .font(.system(size: 12 * size / 32, weight: .bold))
                .foregroundStyle(.red)
        }
    }
}

// The panel's download block, in place of Play while Steam downloads the game
struct DownloadBlock: View {
    let download: DownloadActivity
    let center: ActivityCenter

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(Self.title(download)).font(.headline)
                Spacer()
                Text(verbatim: "\(Int((download.fraction * 100).rounded(.down)))%").monospacedDigit().foregroundStyle(.secondary)
            }
            ActivityBar(fraction: download.fraction,
                        color: download.isFailed ? .red : download.isPaused ? .secondary : .accentColor)
                .accessibilityLabel(Text("Download progress"))
            HStack {
                if case .failed(let reason) = download.state {
                    Text(reason)
                } else if download.bytesTotal > 0 {
                    Text("\(DownloadSummary.size(download.bytesDone)) of \(DownloadSummary.size(download.bytesTotal))")
                        .monospacedDigit()
                }
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                if download.isFailed {
                    Button("Try Again") { center.retry(download.appID) }
                } else {
                    Button(download.isPaused ? "Resume" : "Pause") { center.togglePause(download.appID) }
                }
                Button("Cancel") { center.cancel(download.appID) }
                    .help(Text("Steam asks before it removes what was downloaded"))
            }
            .controlSize(.small)
            if let problem = center.problem {
                Text(problem).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .groupBackground()
    }

    static func title(_ download: DownloadActivity) -> String {
        switch download.state {
        case .failed: String(localized: "Download failed")
        case .paused: String(localized: "Paused")
        case .queued: String(localized: "Waiting to download")
        case .downloading: String(localized: "Downloading")
        }
    }
}

extension DownloadActivity {
    // Under the cover: "Downloading, 34%", "Paused, 34%", "Download failed"
    var cardStatus: String {
        let percent = Int((fraction * 100).rounded(.down))
        switch state {
        case .failed: return String(localized: "Download failed")
        case .paused: return String(localized: "Paused, \(percent)%")
        case .queued: return String(localized: "Waiting to download")
        case .downloading: return String(localized: "Downloading, \(percent)%")
        }
    }
}

extension LibraryModel {
    // Shows a game from the activity slot: its source in the sidebar, selected, with its panel
    func reveal(gameID: String) {
        guard let game = game(gameID) else { return }
        if !games(in: selection).contains(where: { $0.id == gameID }) { selection = .source(game.source) }
        select(gameID)
        showPanel = true
    }
}

// The status item's activity sections: playing, installing, every download, updates
struct ActivityMenuContent: View {
    let center: ActivityCenter

    var body: some View {
        let sections = center.menuSections
        ForEach(sections, id: \.kind) { section in
            Section(section.header) {
                ForEach(Array(section.lines.enumerated()), id: \.offset) { _, line in
                    Text(line.detail.map { "\(line.title)  \($0)" } ?? line.title)
                }
                if section.kind == .playing {
                    Button("Quit Game") { Task { await center.quitGame() } }
                }
            }
        }
        if !sections.isEmpty { Divider() }
    }
}
