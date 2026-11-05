import AppKit
import SwiftUI

struct OverlaySectionView: View {
    @Bindable var center: OverlayCenter
    @Environment(\.overlayLook) private var look

    var body: some View {
        let blocks = center.blocks
        let rows = center.rows
        VStack(alignment: .leading, spacing: OS.s2) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(block, rows: rows)
            }
        }
    }

    @ViewBuilder
    private func view(_ block: OverlayBlock, rows: [OverlayRow]) -> some View {
        switch block {
        case .stats:
            StatsGroup(center: center)
        case .group(let heading, let groupRows):
            if let heading {
                Text(heading)
                    .font(.system(size: OS.t2, weight: .semibold))
                    .foregroundStyle(look.label2)
                    .padding(.horizontal, OS.s2 + OS.s3)
                    .padding(.top, OS.s3)
                    .accessibilityAddTraits(.isHeader)
            }
            OverlayGroup {
                ForEach(Array(groupRows.enumerated()), id: \.element.id) { i, row in
                    if i > 0 && !focused(row, rows) && !focused(groupRows[i - 1], rows) {
                        Rectangle().fill(look.separator).frame(height: 1).padding(.horizontal, OS.s3)
                    }
                    OverlayRowView(center: center, row: row, focused: focused(row, rows))
                }
            }
        case .fold(let row):
            Button { center.pointer(on: row); center.run(.macFold) } label: {
                HStack(spacing: OS.s1) {
                    Text(row.title)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(center.macOpen ? 90 : 0))
                        .animation(look.reduceMotion ? nil : .easeOut(duration: 0.2), value: center.macOpen)
                }
                .font(.system(size: OS.t2, weight: .semibold))
                .foregroundStyle(look.label2)
                .padding(.horizontal, OS.s3)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .background(focused(row, rows) ? look.fill : .clear, in: RoundedRectangle(cornerRadius: OS.row, style: .continuous))
                .overlay { if focused(row, rows) { FocusRing() } }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, OS.s2)
            .accessibilityValue(center.macOpen ? Text(verbatim: "1") : Text(verbatim: "0"))
        case .mac:
            MacGroup(center: center)
        case .loadAlert:
            LoadAlert(center: center)
        case .empty(let symbol, let title, let action):
            OverlayGroup {
                VStack(spacing: 0) {
                    Image(systemName: symbol).font(.system(size: 24)).foregroundStyle(look.label3)
                    Text(title).font(.system(size: OS.t3, weight: .semibold))
                        .padding(.top, OS.s3).padding(.bottom, OS.s1)
                    if let action, case .button(let label, let prominent) = action.control {
                        OverlayButton(title: label, prominent: prominent) { center.run(action.id) }
                            .padding(.top, OS.s3)
                            .overlay { if focused(action, rows) { FocusRing(capsule: true) } }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, OS.s6)
                .padding(.top, OS.s6)
                .padding(.bottom, OS.s4)
            }
        case .soon(let section):
            OverlayGroup {
                VStack(spacing: 0) {
                    Image(systemName: section.symbol).font(.system(size: 24)).foregroundStyle(look.label3)
                    SoonPill().padding(.top, OS.s3)
                    if let teaser = section.feature?.teaser {
                        Text(teaser).font(.system(size: OS.t2)).foregroundStyle(look.label2).padding(.top, OS.s2)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, OS.s6)
                .padding(.top, OS.s6)
                .padding(.bottom, OS.s4)
            }
        case .warning(let text):
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(OS.orange)
                Text(text)
            }
            .font(.system(size: OS.t2))
            .padding(.horizontal, OS.s4)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(look.fill, in: RoundedRectangle(cornerRadius: OS.group, style: .continuous))
        case .notes:
            NotesEditor(center: center)
        }
    }

    private func focused(_ row: OverlayRow, _ rows: [OverlayRow]) -> Bool {
        guard let f = center.focusedRow else { return false }
        return f.id == row.id && rows.firstIndex(where: { $0.id == row.id }) == center.nav.row
    }
}

struct OverlayGroup<Content: View>: View {
    @ViewBuilder var content: () -> Content
    @Environment(\.overlayLook) private var look

    var body: some View {
        VStack(spacing: 0, content: content)
            .padding(OS.s2)
            .background(look.fill, in: RoundedRectangle(cornerRadius: OS.group, style: .continuous))
            .overlay {
                if look.contrast { RoundedRectangle(cornerRadius: OS.group, style: .continuous).strokeBorder(.white.opacity(0.34), lineWidth: 1) }
            }
    }
}

struct FocusRing: View {
    var capsule = false

    var body: some View {
        Group {
            if capsule { Capsule().strokeBorder(OS.focus, lineWidth: 3).padding(-3) }
            else { RoundedRectangle(cornerRadius: OS.row, style: .continuous).strokeBorder(OS.focus, lineWidth: 3).padding(-1.5) }
        }
        .allowsHitTesting(false)
    }
}

struct OverlayRowView: View {
    @Bindable var center: OverlayCenter
    let row: OverlayRow
    var focused = false
    @Environment(\.overlayLook) private var look

    var body: some View {
        Group {
            if case .app = row.control, case .app(let pid) = row.id, let app = center.live.apps.first(where: { $0.pid == pid }) {
                AppRow(center: center, app: app, focused: focused)
            } else {
                HStack(spacing: OS.s4) {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(row.title)
                                .font(.system(size: OS.t2, weight: .medium))
                                .foregroundStyle(titleColor)
                                .lineLimit(1)
                            if row.later { LaterTag() }
                        }
                        if let detail = row.detail, !locked {
                            Text(detail).font(OS.digits(OS.t1, .regular)).foregroundStyle(dimmed ? look.label3 : look.label2)
                        }
                    }
                    .help(row.help ?? "")
                    Spacer(minLength: OS.s4)
                    control
                }
            }
        }
        .padding(.horizontal, OS.s3)
        .padding(.vertical, OS.s2)
        .frame(minHeight: 44)
        .background(focused ? look.fill : .clear, in: RoundedRectangle(cornerRadius: OS.row, style: .continuous))
        .overlay { if focused { FocusRing() } }
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { center.pointer(on: row) })
    }

    private var locked: Bool { if case .locked = row.state { true } else { false } }
    private var dimmed: Bool { if case .disabled = row.state { true } else { false } }
    private var titleColor: Color {
        if locked || dimmed { return look.label3 }
        if case .soon = row.control { return look.label2 }
        return .white
    }

    @ViewBuilder
    private var control: some View {
        if locked {
            Image(systemName: "lock").font(.system(size: 13)).foregroundStyle(look.label3)
                .accessibilityLabel(row.help ?? "")
        } else {
            switch row.control {
            case .segment(let options, let key):
                OverlaySegments(options: options, selection: binding(key), dimmed: dimmed, focused: focused)
                    .disabled(dimmed).opacity(dimmed ? 0.35 : 1)
            case .toggle(let key):
                OverlaySwitch(isOn: Binding(get: { center.binding(key) != 0 }, set: { center.set(key, $0 ? 1 : 0) }), dimmed: dimmed)
                    .disabled(dimmed).opacity(dimmed ? 0.35 : 1)
            case .slider(let key, let lo, let hi, let step, let format):
                OverlaySlider(value: binding(key), range: lo...hi, step: step, text: text(center.binding(key), format), dimmed: dimmed)
                    .disabled(dimmed).opacity(dimmed ? 0.35 : 1)
            case .threshold(let value):
                OverlaySlider(value: Binding(get: { value }, set: { center.run(.threshold, sub: $0) }), range: 30...95, step: 5,
                              text: text(value, .cpu))
            case .button(let label, let prominent):
                OverlayButton(title: label, prominent: prominent) { center.pointer(on: row); center.run(row.id) }
                    .disabled(dimmed).opacity(dimmed ? 0.35 : 1)
            case .corners:
                CornerPicker(selection: binding(.corner))
            case .soon:
                SoonPill()
            default:
                EmptyView()
            }
        }
    }

    private func binding(_ key: SettingKey) -> Binding<Int> {
        Binding(get: { center.binding(key) }, set: { center.pointer(on: row); center.set(key, $0) })
    }

    private func text(_ value: Int, _ format: SliderFormat) -> String {
        switch format {
        case .percent: OverlayFormat.percent(Double(value))
        case .hundredths: OverlayFormat.decimal(Double(value) / 100, digits: 2)
        case .cpu: OverlayFormat.percent(Double(value)) + " CPU"
        }
    }
}

struct AppRow: View {
    @Bindable var center: OverlayCenter
    let app: OverlayApp
    var focused = false
    @Environment(\.overlayLook) private var look

    var body: some View {
        HStack(spacing: OS.s4) {
            HStack(spacing: 9) {
                AppIcon(app: app).opacity(app.paused ? 0.45 : 1)
                Text(verbatim: app.name)
                    .font(.system(size: OS.t2, weight: .medium))
                    .foregroundStyle(app.paused ? look.label3 : .white)
                    .lineLimit(1).truncationMode(.tail)
                    .help(app.name)
            }
            .frame(minWidth: 160, maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 10) {
                bar(OverlayFormat.whole(app.cpu), "% CPU", app.cpu / 60, hot: app.cpu > 20)
                bar(OverlayFormat.whole(app.gpu), "% GPU", app.gpu / 40, hot: app.gpu > 12)
                bar(OverlayFormat.decimal(app.memoryGB), ot("GB"), app.memoryGB / 6, hot: false)
            }
            .frame(width: 240)
            HStack(spacing: 6) {
                if app.system {
                    Label(ot("Managed by macOS"), systemImage: "lock").font(.system(size: OS.t1)).foregroundStyle(look.label2)
                } else {
                    OverlayButton(title: app.paused ? ot("Resume") : ot("Pause"), outlined: focused && center.nav.sub == 0, minWidth: 92 - 2 * OS.s3) {
                        center.appAction(app.pid, sub: 0)
                    }
                    let armed = center.nav.armedApp == app.pid
                    OverlayButton(title: armed ? ot("Confirm") : ot("Quit"), danger: true, armed: armed,
                                  outlined: focused && center.nav.sub == 1, minWidth: 92 - 2 * OS.s3) {
                        center.appAction(app.pid, sub: 1)
                    }
                }
            }
            .frame(minWidth: 190, alignment: .trailing)
        }
    }

    private func bar(_ value: String, _ unit: String, _ fraction: Double, hot: Bool) -> some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(verbatim: value).font(OS.digits(OS.t2))
                Text(verbatim: unit).font(.system(size: OS.t1)).foregroundStyle(look.label2)
            }
            .foregroundStyle(hot ? OS.orange : .white)
            GeometryReader { geo in
                Capsule().fill(OS.fill2)
                    .overlay(alignment: .leading) {
                        Capsule().fill(hot ? OS.orange : look.label2).frame(width: geo.size.width * min(1, max(0, fraction)))
                    }
            }
            .frame(height: 3)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

struct AppIcon: View {
    let app: OverlayApp

    var body: some View {
        if let icon = NSRunningApplication(processIdentifier: app.pid)?.icon {
            Image(nsImage: icon).resizable().frame(width: 22, height: 22)
        } else {
            Text(verbatim: String(app.name.prefix(1)))
                .font(.system(size: OS.t1, weight: .semibold))
                .frame(width: 22, height: 22)
                .background(Color(hue: Double(abs(app.name.hashValue % 360)) / 360, saturation: 0.45, brightness: 0.6),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }
}

struct LoadAlert: View {
    @Bindable var center: OverlayCenter
    @Environment(\.overlayLook) private var look

    var body: some View {
        let over = center.live.othersCPU > Double(center.threshold)
        let percent = OverlayFormat.percent(center.live.othersCPU)
        HStack(spacing: 10) {
            if over {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(OS.orange)
                (Text(ot("Mac overloaded")).fontWeight(.semibold) + Text(String(format: ot(": other apps at %@ of the CPU"), percent)))
            } else {
                Text(String(format: ot("Other apps: %@ of the CPU"), percent))
            }
        }
        .font(.system(size: OS.t2))
        .foregroundStyle(over ? Color.white : look.label2)
        .padding(.horizontal, OS.s4)
        .padding(.vertical, OS.s2)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .background(look.fill, in: RoundedRectangle(cornerRadius: OS.group, style: .continuous))
    }
}

struct NotesEditor: View {
    @Bindable var center: OverlayCenter
    @FocusState private var focused: Bool
    @Environment(\.overlayLook) private var look

    var body: some View {
        TextEditor(text: $center.notes)
            .font(.system(size: OS.t2))
            .lineSpacing(OS.t2 * 0.55)
            .scrollContentBackground(.hidden)
            .focused($focused)
            .padding(.horizontal, OS.s4 - 5)
            .padding(.vertical, OS.s3)
            .frame(minHeight: 200)
            .background(look.fill, in: RoundedRectangle(cornerRadius: OS.group, style: .continuous))
            .overlay(alignment: .topLeading) {
                if center.notes.isEmpty {
                    Text(ot("Codes, settings, where you are…"))
                        .font(.system(size: OS.t2)).foregroundStyle(look.label3)
                        .padding(.horizontal, OS.s4).padding(.vertical, OS.s3)
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                if focused { RoundedRectangle(cornerRadius: OS.group, style: .continuous).strokeBorder(OS.focus, lineWidth: 3) }
            }
            .accessibilityLabel(String(format: ot("Notes for %@"), center.game.name))
    }
}
