import AppKit
import SwiftUI

// One row of « Apps en arrière-plan »: CPU and GPU as a share of the whole Mac, as the in-game menu shows them
struct BackgroundAppRow: Identifiable, Equatable {
    enum Kind: Equatable { case app, system, protected, game, launcher, rest }

    var id: pid_t { usage.pid }
    var usage: ResourceUsage
    var cpu: Double
    var gpu: Double
    var memory: UInt64
    var kind: Kind
    var paused: Bool
}

// The « Apps » header's sorters: a click sorts descending, a second click reverses
enum AppsColumn { case cpu, gpu, memory }

struct AppsSort: Equatable {
    var column: AppsColumn = .cpu
    var ascending = false

    mutating func tap(_ column: AppsColumn) {
        if column == self.column { ascending.toggle() } else { self.column = column; ascending = false }
    }
}

extension BackgroundAppRow {
    static func sorted(_ rows: [BackgroundAppRow], by sort: AppsSort) -> [BackgroundAppRow] {
        rows.sorted {
            let a = $0.value(sort.column), b = $1.value(sort.column)
            if a == b { return $0.usage.name.localizedStandardCompare($1.usage.name) == .orderedAscending }
            return sort.ascending ? a < b : a > b
        }
    }

    private func value(_ column: AppsColumn) -> Double {
        switch column {
        case .cpu: cpu
        case .gpu: gpu
        case .memory: Double(memory)
        }
    }
}

extension ResourceMonitor {
    // Apps lists only what Pause and Quit can act on; « Tout » lists every process macOS shows
    func backgroundRows(all: Bool) -> [BackgroundAppRow] {
        guard let sample else { return [] }
        let cores = Double(max(1, sample.cores))
        var rows = sample.rows.compactMap { row -> BackgroundAppRow? in
            let protection = protection(of: row)
            if protection == .cartouche { return nil }
            guard all || protection == nil else { return nil }
            guard all || row.isApp || (row.cpu ?? 0) >= 5 || (row.gpu ?? 0) >= 2 else { return nil }
            let kind: BackgroundAppRow.Kind = switch protection {
            case .system?: .system
            case .user?: .protected
            case .game?: .game
            case .launcher?: .launcher
            default: .app
            }
            return BackgroundAppRow(usage: row, cpu: (row.cpu ?? 0) / cores, gpu: row.gpu ?? 0, memory: row.memory ?? 0,
                                    kind: kind, paused: isPaused(row))
        }
        // The Steam client's many processes read as one line
        let launchers = rows.filter { $0.kind == .launcher }
        if launchers.count > 1 {
            rows.removeAll { $0.kind == .launcher }
            rows.append(mergedLauncher(launchers))
        }
        rows.sort { ($0.kind == .game ? 1 : 0, $0.cpu) > ($1.kind == .game ? 1 : 0, $1.cpu) }
        // « Tout » ends with what the listed rows do not explain of the Mac's load
        if all { rows.append(restRow(rows, sample: sample)) }
        return rows
    }

    private func mergedLauncher(_ launchers: [BackgroundAppRow]) -> BackgroundAppRow {
        let base = launchers.first { $0.usage.isApp } ?? launchers[0]
        return BackgroundAppRow(
            usage: ResourceUsage(pid: base.usage.pid, name: base.usage.isApp ? base.usage.name : "Steam",
                                 bundleID: base.usage.bundleID, bundlePath: base.usage.bundlePath,
                                 pids: launchers.flatMap { $0.usage.pids }),
            cpu: launchers.reduce(0) { $0 + $1.cpu }, gpu: launchers.reduce(0) { $0 + $1.gpu },
            memory: launchers.reduce(0) { $0 + $1.memory }, kind: .launcher,
            paused: launchers.contains(where: \.paused))
    }

    private func restRow(_ rows: [BackgroundAppRow], sample: ResourceSample) -> BackgroundAppRow {
        let listed = (cpu: rows.reduce(0) { $0 + $1.cpu }, gpu: rows.reduce(0) { $0 + $1.gpu },
                      memory: rows.reduce(0) { $0 + $1.memory })
        let memory = sample.memory.used > listed.memory ? sample.memory.used - listed.memory : 0
        return BackgroundAppRow(usage: ResourceUsage(pid: pid_t.max, name: ot("System and Others"), pids: []),
                                cpu: max(0, sample.cpuLoad - listed.cpu),
                                gpu: sample.gpuDevice.map { max(0, $0 - listed.gpu) } ?? 0,
                                memory: memory, kind: .rest, paused: false)
    }

    var macOverloaded: Bool {
        guard let sample else { return false }
        let fixed = Set(protection.filter { $0.value != .user }.keys)
        return LoadCheck.verdict(sample, game: gamePIDs, protected: fixed, thresholds: thresholds) != nil
    }

    // Two readings half a second apart, the least a CPU share needs
    func quickCheck() async -> Bool {
        if sample == nil {
            await refresh()
            try? await sleep(.milliseconds(500))
        }
        await refresh()
        return macOverloaded
    }
}

// The grid the mockup aligns everything on: 44 pt edges, fixed columns, units in a box of their own
enum BackgroundAppsGrid {
    static let edge: CGFloat = 44
    static let column: CGFloat = 104
    static let memoryColumn: CGFloat = 136
    static let actions: CGFloat = 196
    static let gap: CGFloat = 12
    static let unit: CGFloat = 38
    static let maxWidth: CGFloat = 940
    static let rowHeight: CGFloat = 44
}

struct BackgroundAppsView: View {
    @Bindable var monitor: ResourceMonitor
    @Bindable var presenter: BackgroundAppsPresenter
    var gameName: String?
    var maxHeight: CGFloat = 800

    @Environment(\.locale) private var locale
    @State private var showAll = false
    @State private var sort = AppsSort()
    @State private var contentHeight: CGFloat = 400
    @State private var order: [pid_t] = []
    @State private var armed: pid_t?
    @State private var leaving: Set<pid_t> = []
    @State private var icons = AppIcons()

    private typealias G = BackgroundAppsGrid

    // Rows keep their place while the window is open: nothing moves under the pointer.
    // « Système et autres » never joins the sort: it stays last.
    private var rows: [BackgroundAppRow] {
        let fresh = monitor.backgroundRows(all: showAll).filter { !leaving.contains($0.id) }
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return fresh.sorted {
            (rank[$0.id] ?? Int.max, $0.kind == .rest ? 1 : 0, -$0.cpu)
                < (rank[$1.id] ?? Int.max, $1.kind == .rest ? 1 : 0, -$1.cpu)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 0) { content }
                    .padding(.horizontal, G.edge - 20)
                    .padding(.vertical, 8)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .frame(height: min(contentHeight, max(160, maxHeight - 124)))
            .scrollIndicators(.never)
            .softScrollEdges(top: 12, bottom: 16)
            footer
        }
        .onAppear { monitor.startViewing() }
        .onDisappear { monitor.stopViewing() }
        .onChange(of: monitor.sample) { remember() }
        .onChange(of: showAll) { resort() }
    }

    private func remember() {
        let ids = monitor.backgroundRows(all: showAll).filter { $0.kind != .rest }.map(\.id)
        order += ids.filter { !order.contains($0) }
    }

    private func resort() {
        order = BackgroundAppRow.sorted(monitor.backgroundRows(all: showAll).filter { $0.kind != .rest }, by: sort).map(\.id)
    }

    // MARK: Header and footer

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(ot("Mac Resources")).font(.system(size: 15, weight: .semibold))
                if let gameName {
                    HStack(spacing: 6) {
                        Circle().fill(Color.green).frame(width: 6, height: 6)
                        Text(verbatim: gameName).lineLimit(1)
                    }
                    .font(.system(size: 11)).foregroundStyle(Glass.label2)
                }
            }
            Spacer(minLength: 12)
            PageSegmented(title: ot("Apps"), options: [.init(value: false, title: ot("Apps")), .init(value: true, title: ot("All"))],
                          selection: $showAll)
                .frame(width: 150)
        }
        .padding(EdgeInsets(top: 16, leading: G.edge, bottom: 8, trailing: G.edge))
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if presenter.mode == .play {
                Toggle(ot("Don't show again this session"), isOn: $presenter.muteChecked)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 13))
                    .foregroundStyle(Glass.label2)
            }
            Spacer(minLength: 8)
            if presenter.mode != .play && !monitor.pausedPIDs.isEmpty {
                Button(ot("Resume All")) { monitor.resumeAll(why: "the user asked") }
                    .buttonStyle(.pill)
                    .controlSize(.large)
            }
            if presenter.mode == .play {
                Button(String(localized: "Cancel")) { presenter.close() }
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "Play")) { presenter.close(play: true) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent).tint(Glass.accentFill)
            } else {
                Button(String(localized: "Done")) { presenter.close() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent).tint(Glass.accentFill)
                    .background {
                        Button("") { presenter.close() }
                            .keyboardShortcut(.cancelAction)
                            .opacity(0)
                            .accessibilityHidden(true)
                    }
            }
        }
        .controlSize(.large)
        .padding(EdgeInsets(top: 12, leading: G.edge, bottom: 16, trailing: G.edge))
    }

    // MARK: Body

    @ViewBuilder
    private var content: some View {
        group { summary }
        if monitor.macOverloaded, let sample = monitor.sample {
            alert(LoadCheck.otherCPU(sample, game: monitor.gamePIDs))
                .padding(.top, 8)
        }
        appsHeader
        group { list }
        sectionHeader(ot("Warning"))
        group {
            thresholdRow
            separator
            HStack {
                Text(ot("Resume Apps After the Game")).font(.system(size: 13, weight: .medium))
                Spacer()
                Toggle(ot("Resume Apps After the Game"), isOn: $monitor.resumesAfterGame)
                    .toggleStyle(.switch).labelsHidden()
            }
            .frame(minHeight: G.rowHeight)
            .padding(.horizontal, 12)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(verbatim: title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Glass.label2)
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 8)
            .accessibilityAddTraits(.isHeader)
    }

    // « Apps »'s header line carries the column titles: click sorts, a second click reverses
    private var appsHeader: some View {
        columns(height: 13) {
            Text(ot("Apps"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Glass.label2)
        } cpu: {
            sortButton(.cpu, "CPU")
        } gpu: {
            sortButton(.gpu, "GPU")
        } memory: {
            sortButton(.memory, "RAM")
        } actions: {
            EmptyView()
        }
        .padding(.horizontal, 8)
        .padding(.top, 16)
        .padding(.bottom, 8)
        .accessibilityAddTraits(.isHeader)
    }

    private func sortButton(_ column: AppsColumn, _ title: String) -> some View {
        Button {
            sort.tap(column)
            resort()
        } label: {
            HStack(spacing: 3) {
                Text(verbatim: title)
                if sort.column == column {
                    Image(systemName: sort.ascending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                }
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Glass.label2)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, G.unit)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func group<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 0, content: content)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .groupBackground(radius: Glass.panelRadius)
    }

    private var separator: some View {
        Rectangle().fill(Glass.separator).frame(height: 1).padding(.horizontal, 12)
    }

    // « Ce Mac » on the list's columns: CPU, GPU and memory over theirs, Swap over the buttons
    @ViewBuilder
    private var summary: some View {
        if let sample = monitor.sample {
            let memory = sample.memory
            let hot: Color? = memory.pressure == .critical ? .red : memory.pressure == .warning ? .orange : nil
            columns(height: 52) {
                name(Text(ot("Your Mac")), icon: AnyView(MacGlyph()))
            } cpu: {
                LoadMeter(value: BackgroundAppsFormat.percent(sample.cpuLoad, locale: locale), unit: "% CPU",
                          fraction: sample.cpuLoad / 100, tint: monitor.macOverloaded ? .orange : nil, large: true)
            } gpu: {
                LoadMeter(value: BackgroundAppsFormat.percent(sample.gpuDevice, locale: locale), unit: "% GPU",
                          fraction: (sample.gpuDevice ?? 0) / 100, large: true)
            } memory: {
                LoadMeter(value: BackgroundAppsFormat.memory(used: memory.used, physical: memory.physical, locale: locale),
                          unit: ot("GB"), fraction: memory.physical > 0 ? Double(memory.used) / Double(memory.physical) : 0,
                          tint: hot, large: true)
            } actions: {
                // Swap has no bar: the mockup pins it to the top of the row (acts.swap)
                LoadMeter(value: BackgroundAppsFormat.gigabytes(memory.swapUsed, locale: locale), unit: ot("GB"),
                          fraction: nil, large: true, label: ot("Swap"))
                    .padding(.top, 12)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
            .accessibilityElement(children: .combine)
        } else {
            columns(height: 52) {
                name(Text(ot("Your Mac")), icon: AnyView(MacGlyph()))
            } cpu: { Skeleton() } gpu: { Skeleton() } memory: { Skeleton() } actions: { Skeleton().frame(width: 92) }
        }
    }

    @ViewBuilder
    private var list: some View {
        let rows = rows
        if monitor.sample == nil {
            ForEach(0..<4, id: \.self) { i in
                if i > 0 { separator }
                columns { HStack(spacing: 9) { Skeleton().frame(width: 22, height: 22); Skeleton().frame(width: 120) } }
                    cpu: { Skeleton() } gpu: { Skeleton() } memory: { Skeleton() } actions: { Skeleton().frame(width: 92) }
            }
        } else if rows.isEmpty {
            VStack(spacing: 4) {
                Image(systemName: "checkmark.circle").font(.system(size: 22)).foregroundStyle(Glass.label2)
                Text(gameName == nil ? ot("No Heavy Apps") : ot("Nothing slows the game"))
                    .font(.system(size: 15, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32)
        } else {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 { separator }
                appRow(row)
            }
        }
    }

    private func appRow(_ row: BackgroundAppRow) -> some View {
        let dim = row.paused
        return columns {
            HStack(spacing: 9) {
                if row.kind == .rest {
                    Image(systemName: "gearshape").font(.system(size: 14))
                        .foregroundStyle(Glass.label2)
                        .frame(width: 22, height: 22)
                        .background(Glass.fill2, in: RoundedRectangle(cornerRadius: 5))
                        .accessibilityHidden(true)
                } else {
                    Image(nsImage: icons.icon(for: row.usage)).resizable().frame(width: 22, height: 22)
                        .opacity(dim ? 0.45 : 1).accessibilityHidden(true)
                }
                Text(verbatim: row.usage.name).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.tail)
                    .foregroundStyle(dim ? Glass.label3 : Color.primary)
                    .help(row.usage.name)
                if dim {
                    Text(ot("Paused")).font(.system(size: 11, weight: .semibold)).foregroundStyle(Glass.label2)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Glass.fill2, in: .capsule)
                        .fixedSize()
                }
            }
        } cpu: {
            LoadMeter(value: BackgroundAppsFormat.percent(dim ? 0 : row.cpu, locale: locale), unit: "% CPU",
                      fraction: dim ? 0 : row.cpu / 100, tint: !dim && row.kind == .app && row.cpu >= 20 ? .orange : nil, dim: dim)
        } gpu: {
            LoadMeter(value: BackgroundAppsFormat.percent(dim ? 0 : row.gpu, locale: locale), unit: "% GPU",
                      fraction: dim ? 0 : row.gpu / 100, tint: !dim && row.kind == .app && row.gpu >= 15 ? .orange : nil, dim: dim)
        } memory: {
            LoadMeter(value: BackgroundAppsFormat.gigabytes(row.memory, locale: locale), unit: ot("GB"),
                      fraction: Double(row.memory) / (8 * BackgroundAppsFormat.gigabyte), dim: dim)
        } actions: {
            actions(row)
        }
        .contentShape(Rectangle())
        .contextMenu {
            if row.kind == .app {
                Button(ot("Force Quit")) { monitor.perform(.forceQuit, on: row.usage) }
            }
        }
        .transition(.asymmetric(insertion: .opacity, removal: .opacity.combined(with: .offset(x: 8))))
    }

    @ViewBuilder
    private func actions(_ row: BackgroundAppRow) -> some View {
        switch row.kind {
        case .system: lockLabel(ot("Managed by macOS"), symbol: "lock")
        case .protected, .launcher: lockLabel(ot("Protected"), symbol: "lock")
        case .rest: EmptyView()
        case .game:
            HStack(spacing: 5) {
                Circle().fill(Color.green).frame(width: 6, height: 6)
                Text(ot("Current game"))
            }
            .font(.system(size: 11)).foregroundStyle(Glass.label2)
        case .app:
            HStack(spacing: 6) {
                Button(row.paused ? ot("Resume") : ot("Pause")) {
                    armed = nil
                    monitor.perform(row.paused ? .resume : .pause, on: row.usage)
                }
                .buttonStyle(RowButtonStyle())
                Button(armed == row.id ? ot("Confirm") : ot("Quit")) { quit(row) }
                    .buttonStyle(RowButtonStyle(role: armed == row.id ? .armed : .destructive))
            }
        }
    }

    // Quit asks once in place; the button goes back after three seconds
    private func quit(_ row: BackgroundAppRow) {
        guard armed == row.id else {
            armed = row.id
            Task {
                try? await Task.sleep(for: .seconds(3))
                if armed == row.id { armed = nil }
            }
            return
        }
        armed = nil
        monitor.perform(.quit, on: row.usage)
        withAnimation(.easeOut(duration: 0.16)) { _ = leaving.insert(row.id) }
    }

    private func lockLabel(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 11))
            .foregroundStyle(Glass.label2)
            .labelStyle(.titleAndIcon)
    }

    private func name(_ text: Text, icon: AnyView) -> some View {
        HStack(spacing: 9) {
            icon
            text.font(.system(size: 13, weight: .medium)).lineLimit(1)
        }
    }

    private var thresholdRow: some View {
        HStack(spacing: 12) {
            Text(ot("Alert Threshold")).font(.system(size: 13, weight: .medium))
            Spacer(minLength: 12)
            Slider(value: Binding(get: { monitor.thresholds.otherCPU },
                                  set: { let v = ($0 / 5).rounded() * 5
                                         monitor.thresholds.otherCPU = v
                                         monitor.thresholds.otherGPU = v }),
                   in: 30...95)
                .frame(width: 170)
                .labelsHidden()
                .accessibilityLabel(Text(ot("Alert Threshold")))
            Text(verbatim: OverlayFormat.percent(monitor.thresholds.otherCPU) + " CPU")
                .font(.system(size: 13)).monospacedDigit().foregroundStyle(Glass.label2)
                .frame(minWidth: 64, alignment: .trailing)
        }
        .frame(minHeight: G.rowHeight)
        .padding(.horizontal, 12)
    }

    private func alert(_ cpu: Double) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityHidden(true)
            Text(overloadLine(cpu)).font(.system(size: 13))
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, minHeight: G.rowHeight, alignment: .leading)
        .groupBackground(radius: Glass.panelRadius)
        .help(Text(verbatim: String(format: ot("Threshold: %@"), OverlayFormat.percent(monitor.thresholds.otherCPU) + " CPU")))
        .accessibilityElement(children: .combine)
    }

    private func overloadLine(_ cpu: Double) -> AttributedString {
        var head = AttributedString(ot("Mac overloaded"))
        head.font = .system(size: 13, weight: .semibold)
        return head + AttributedString(String(format: ot(": other apps at %@ of the CPU"), OverlayFormat.percent(cpu)))
    }

    private func columns<N: View, C: View, P: View, M: View, A: View>(
        height: CGFloat = BackgroundAppsGrid.rowHeight,
        @ViewBuilder name: () -> N, @ViewBuilder cpu: () -> C, @ViewBuilder gpu: () -> P,
        @ViewBuilder memory: () -> M, @ViewBuilder actions: () -> A
    ) -> some View {
        HStack(spacing: G.gap) {
            name().frame(maxWidth: .infinity, alignment: .leading)
            cpu().frame(width: G.column)
            gpu().frame(width: G.column)
            memory().frame(width: G.memoryColumn)
            actions().frame(width: G.actions, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .frame(height: height)
    }
}

// A number over its bar. Every column stacks the same way, so the numbers of a row share one baseline.
struct LoadMeter: View {
    let value: String
    let unit: String
    let fraction: Double?
    var tint: Color?
    var large = false
    var dim = false
    var label: String?

    var body: some View {
        VStack(spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if let label {
                    Spacer(minLength: 0)
                    Text(verbatim: label).font(.system(size: 11)).foregroundStyle(Glass.label2).padding(.trailing, 4)
                }
                Text(verbatim: value)
                    .font(.system(size: large ? 15 : 13, weight: large ? .semibold : .medium))
                    .monospacedDigit()
                    .foregroundStyle(dim ? Glass.label3 : tint ?? Color.primary)
                    .lineLimit(1)
                    .frame(maxWidth: label == nil ? .infinity : nil, alignment: .trailing)
                Text(verbatim: unit)
                    .font(.system(size: 11))
                    .foregroundStyle(Glass.label2)
                    .lineLimit(1)
                    .frame(width: BackgroundAppsGrid.unit, alignment: .leading)
            }
            if let fraction {
                ZStack(alignment: .leading) {
                    Capsule().fill(Glass.fill2)
                    GeometryReader { geo in
                        Capsule().fill(tint ?? Glass.label2)
                            .frame(width: geo.size.width * min(1, max(0, fraction)))
                            .animation(.linear(duration: 0.4), value: fraction)
                    }
                }
                .frame(height: 3)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct Skeleton: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 4).fill(Glass.fill2).frame(height: 13).frame(maxWidth: .infinity)
    }
}

private struct MacGlyph: View {
    var body: some View {
        Image(systemName: "desktopcomputer")
            .font(.system(size: 11, weight: .medium))
            .frame(width: 22, height: 22)
            .background(Glass.fill2, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .accessibilityHidden(true)
    }
}

// The row's Pause and Quit: 28 pt capsules, Quit in red, red filled once armed
struct RowButtonStyle: ButtonStyle {
    enum Role { case normal, destructive, armed }
    var role = Role.normal

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(role == .armed ? Color.white : role == .destructive ? Color.red : Color.primary)
            .lineLimit(1)
            .frame(minWidth: 68)
            .padding(.horizontal, 12)
            .frame(width: 92, height: 28)
            .background(role == .armed ? Color.red : Glass.fill2, in: .capsule)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .contentShape(.capsule)
    }
}

// The window over the library: a scrim on the main window only, the panel centred, glass
struct BackgroundAppsOverlay: View {
    let monitor: ResourceMonitor
    @Bindable var presenter: BackgroundAppsPresenter
    var gameName: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if presenter.isOpen {
                    Color.black.opacity(0.18)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture { presenter.close() }
                        .transition(.opacity)
                        .accessibilityHidden(true)
                    BackgroundAppsView(monitor: monitor, presenter: presenter, gameName: gameName, maxHeight: geo.size.height - 96)
                        .frame(width: min(BackgroundAppsGrid.maxWidth, geo.size.width - 96))
                        .floatingPanel(radius: Glass.windowRadius)
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.96).combined(with: .opacity).combined(with: .offset(y: 8)))
                        .accessibilityAddTraits(.isModal)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.26, bounce: 0), value: presenter.isOpen)
        }
    }
}
