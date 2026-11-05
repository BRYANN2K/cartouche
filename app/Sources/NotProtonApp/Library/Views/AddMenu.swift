import AppKit
import RetroArchKit
import SwiftUI

struct AddMenuItem: Identifiable, Equatable {
    enum State: Equatable {
        case available
        // Its core is on the way
        case pending
        // Added since the menu opened: one more click takes it back
        case added
        case locked
    }

    let id: String
    let name: String
    let badge: PlatformBadge
    var group: String?
    var note: String?
    let state: State

    var acts: Bool { state == .available || state == .added }
}

extension [AddMenuItem] {
    var isSettled: Bool { allSatisfy { $0.state == .locked } }
}

enum AddMenuKeyboard {
    enum Action: Equatable {
        case close, none
        case move(String)
        case toggle(String)
    }

    static func action(_ key: KeyEquivalent, cursor: String?, items: [AddMenuItem]) -> Action {
        let stops = items.filter(\.acts)
        let at = stops.firstIndex { $0.id == cursor }
        switch key {
        case .escape:
            return .close
        case .downArrow, .upArrow:
            guard !stops.isEmpty else { return .none }
            let step = key == .downArrow ? 1 : -1
            let start = at ?? (key == .downArrow ? -1 : 0)
            return .move(stops[(start + step + stops.count) % stops.count].id)
        case .home:
            return stops.first.map { .move($0.id) } ?? .none
        case .end:
            return stops.last.map { .move($0.id) } ?? .none
        case .return, .space:
            return at.map { .toggle(stops[$0].id) } ?? .none
        default:
            return .none
        }
    }

    static func key(_ code: UInt16) -> KeyEquivalent? {
        switch code {
        case 53: .escape
        case 125: .downArrow
        case 126: .upArrow
        case 115: .home
        case 119: .end
        case 36, 76: .return
        case 49: .space
        default: nil
        }
    }

    static func match(_ typed: String, items: [AddMenuItem]) -> String? {
        items.first { $0.acts && $0.name.lowercased().hasPrefix(typed.lowercased()) }?.id
    }
}

struct AddMenu: View {
    let title: Text
    let empty: Text
    let items: (Set<String>) -> [AddMenuItem]
    let add: (String) -> Void
    let undo: (String) -> Void

    @State private var added: Set<String> = []
    @State private var cursor: String?
    @State private var typed = ""
    @State private var typing: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let rowHeight: CGFloat = 40
    private static let groupHeight: CGFloat = 29
    private static let tallest: CGFloat = 520

    static func stores(_ model: LibraryModel) -> AddMenu {
        AddMenu(title: Text("Add Stores"), empty: Text("All stores added"),
                items: { model.storeMenu(added: $0) },
                add: { id in GameSource.pc.first { $0.id == id }.map(model.addStore) },
                undo: { id in GameSource.pc.first { $0.id == id }.map(model.unaddStore) })
    }

    static func consoles(_ center: ConsoleCenter) -> AddMenu {
        AddMenu(title: Text("Add Consoles"), empty: Text("All consoles added"),
                items: { center.consoleMenu(added: $0) },
                add: { center.enqueueAdd($0) },
                undo: { id in Task { await center.unadd(id) } })
    }

    var body: some View {
        let rows = items(added)
        let left = rows.contains { $0.state == .available || $0.state == .pending }
        VStack(alignment: .leading, spacing: 0) {
            title
                .font(.system(size: 13, weight: .semibold))
                .padding(EdgeInsets(top: 12, leading: 16, bottom: 7, trailing: 16))
                .accessibilityAddTraits(.isHeader)
            if rows.isSettled {
                Label {
                    empty.foregroundStyle(Glass.label2)
                } icon: {
                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                }
                .font(.system(size: 13))
                .padding(EdgeInsets(top: 6, leading: 16, bottom: 15, trailing: 16))
            } else {
                list(rows)
            }
        }
        .frame(width: 312, alignment: .leading)
        .background(KeyCatcher { handle($0, rows) })
        // The last one in: the row shows its check, then the menu settles on its one line
        .task(id: left) {
            guard !left, !added.isEmpty else { return }
            try? await Task.sleep(for: .seconds(0.9))
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.26)) { added = [] }
        }
    }

    private func list(_ rows: [AddMenuItem]) -> some View {
        let groups = sections(rows)
        let height = CGFloat(rows.count) * Self.rowHeight + 6
            + CGFloat(groups.filter { $0.title != nil }.count) * Self.groupHeight
        return ScrollViewReader { scroller in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(groups, id: \.id) { group in
                        if let title = group.title {
                            Text(verbatim: title)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Glass.label2)
                                .padding(EdgeInsets(top: 11, leading: 10, bottom: 4, trailing: 10))
                                .frame(height: Self.groupHeight, alignment: .bottomLeading)
                                .accessibilityAddTraits(.isHeader)
                        }
                        ForEach(group.rows) { item in
                            AddMenuRow(item: item, highlighted: cursor == item.id) { toggle(item) }
                                .id(item.id)
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
            }
            .scrollIndicators(.never)
            .softScrollEdges(top: 10, bottom: 18)
            .frame(height: min(height, Self.tallest))
            .onChange(of: cursor) { _, id in
                if let id { scroller.scrollTo(id) }
            }
        }
    }

    private func sections(_ rows: [AddMenuItem]) -> [(id: Int, title: String?, rows: [AddMenuItem])] {
        var result: [(id: Int, title: String?, rows: [AddMenuItem])] = []
        for row in rows {
            if let last = result.indices.last, result[last].title == row.group {
                result[last].rows.append(row)
            } else {
                result.append((result.count, row.group, [row]))
            }
        }
        return result
    }

    private func toggle(_ item: AddMenuItem) {
        switch item.state {
        case .available:
            added.insert(item.id)
            add(item.id)
        case .added:
            added.remove(item.id)
            undo(item.id)
        case .pending, .locked:
            break
        }
    }

    private func handle(_ event: NSEvent, _ rows: [AddMenuItem]) -> Bool {
        let key = AddMenuKeyboard.key(event.keyCode) ?? KeyEquivalent("\0")
        switch AddMenuKeyboard.action(key, cursor: cursor, items: rows) {
        case .close:
            dismiss()
            return true
        case .move(let id):
            cursor = id
            return true
        case .toggle(let id):
            rows.first { $0.id == id }.map(toggle)
            return true
        case .none:
            break
        }
        guard event.modifierFlags.isDisjoint(with: [.command, .control, .option]),
              let characters = event.characters, characters.first?.isLetter == true || characters.first?.isNumber == true
        else { return false }
        typed += characters
        typing?.cancel()
        typing = Task {
            try? await Task.sleep(for: .seconds(0.7))
            if !Task.isCancelled { typed = "" }
        }
        if let hit = AddMenuKeyboard.match(typed, items: rows) { cursor = hit }
        return true
    }
}

// A popover of plain buttons never takes the keyboard: while it is open the app's keys come here first, so arrows reach the menu and not the sidebar behind it
private struct KeyCatcher: NSViewRepresentable {
    let press: (NSEvent) -> Bool

    final class Catcher: NSView {
        var press: (NSEvent) -> Bool = { _ in false }
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.press(event) == true ? nil : event
            }
        }
    }

    func makeNSView(context: Context) -> Catcher { Catcher() }

    func updateNSView(_ view: Catcher, context: Context) { view.press = press }
}

private struct AddMenuRow: View {
    let item: AddMenuItem
    let highlighted: Bool
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var locked: Bool { item.state == .locked }
    private var checked: Bool { item.state == .added || locked }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                BrandMark(badge: item.badge, size: 28)
                    .opacity(locked ? 0.5 : 1)
                Text(verbatim: item.name)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(locked ? Glass.label2 : Color.primary)
                Spacer(minLength: 8)
                if let note = item.note, !checked {
                    Text(verbatim: note)
                        .font(.system(size: 11))
                        .foregroundStyle(Glass.label2)
                        .lineLimit(1)
                        .fixedSize()
                }
                tick
            }
            .padding(.leading, 6)
            .padding(.trailing, 10)
            .frame(height: 40)
            .background {
                if (hovering || highlighted) && !locked {
                    RoundedRectangle(cornerRadius: Glass.rowRadius, style: .continuous).fill(Glass.fill)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!item.acts)
        .trackHover { hovering = $0 }
        .help(Text(verbatim: item.name))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(checked ? String(localized: "\(item.name), added") : String(localized: "Add \(item.name)"))
        .accessibilityValue(item.note ?? "")
        .accessibilityAddTraits(checked ? .isSelected : [])
    }

    @ViewBuilder private var tick: some View {
        Group {
            if item.state == .pending {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: checked ? "checkmark" : "plus")
                    .font(.system(size: 12, weight: checked ? .bold : .medium))
                    .foregroundStyle(locked ? Glass.label3 : checked ? Color.accentColor : Glass.label2)
                    .opacity(checked || hovering || highlighted ? 1 : 0)
                    .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                    .animation(reduceMotion ? nil : .snappy(duration: 0.24), value: checked)
            }
        }
        .frame(width: 16, height: 16)
    }
}
