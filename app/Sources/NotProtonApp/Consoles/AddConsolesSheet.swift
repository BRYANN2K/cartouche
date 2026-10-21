import RetroArchKit
import SwiftUI

struct AddConsolesChoice: Equatable {
    var picked: [String] = []

    mutating func toggle(_ id: String) {
        if let i = picked.firstIndex(of: id) { picked.remove(at: i) } else { picked.append(id) }
    }

    var addTitle: String {
        switch picked.count {
        case 0: String(localized: "Add")
        case 1: String(localized: "Add 1 Console")
        default: String(localized: "Add \(picked.count) Consoles")
        }
    }
}

struct AddConsolesSheet: View {
    let center: ConsoleCenter
    @State var choice = AddConsolesChoice()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: Text("Add Consoles"),
                        message: Text("Pick the systems you play. Cartouche downloads only their cores, from libretro."))
                .padding(.bottom, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(ConsoleMaker.allCases, id: \.self) { maker in
                        let consoles = ConsoleCatalog.made(by: maker)
                        if !consoles.isEmpty {
                            Text(verbatim: maker.title)
                                .groupHeader()
                                .padding(.horizontal, 5)
                                .padding(.top, 14)
                                .padding(.bottom, 6)
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                                ForEach(consoles) { console in
                                    AddConsoleTile(console: console, added: center.isAdded(console.id),
                                                picked: choice.picked.contains(console.id),
                                                found: center.found[console.id] ?? 0) {
                                        choice.toggle(console.id)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 8)
            }
            .softScrollEdges()
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.sheet)
                    .keyboardShortcut(.cancelAction)
                Button(choice.addTitle) {
                    let ids = choice.picked
                    dismiss()
                    Task { await center.add(ids) }
                }
                .buttonStyle(.sheetProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(choice.picked.isEmpty)
            }
            .padding(.top, 14)
        }
        .padding(22)
        .frame(width: 660, height: 600)
    }
}

struct AddConsoleTile: View {
    let console: Console
    let added: Bool
    let picked: Bool
    let found: Int
    let toggle: () -> Void

    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        Button(action: toggle) {
            VStack(alignment: .leading, spacing: 2) {
                ConsoleMarkView(id: console.id, size: 20)
                    .foregroundStyle(Color.accentColor)
                    .frame(height: 20)
                    .padding(.bottom, 4)
                Text(verbatim: console.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(added ? String(localized: "Added") : console.coreName)
                    .font(.system(size: 11))
                    .foregroundStyle(Glass.label2)
                    .lineLimit(1)
                if console.bios != .none && !added {
                    Text("Needs BIOS")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.orange)
                }
                if found > 0 && !added {
                    Text(found == 1 ? String(localized: "1 game found") : String(localized: "\(found) games found"))
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.green)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 82, alignment: .topLeading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(picked ? Color.accentColor.opacity(0.12) : hovering && !added ? Glass.fill2 : Glass.fill, in: shape)
            .overlay {
                if picked { shape.strokeBorder(Color.accentColor, lineWidth: 2) }
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .disabled(added)
        .opacity(added ? 0.5 : 1)
        .accessibilityAddTraits(picked ? .isSelected : [])
    }
}

struct ConsoleSidebarRow: View {
    let id: String
    @Bindable var model: LibraryModel
    @Environment(ConsoleCenter.self) private var consoles: ConsoleCenter?

    var body: some View {
        let item = SidebarItem.source(.console(id))
        SidebarRow(title: LibraryModel.title(item), badge: model.badge(item), selected: model.selection == item,
                   icon: { ConsoleMarkView(id: id) }) {
            model.selection = item
        }
        .contextMenu {
            if let consoles {
                ForEach(consoles.menu(for: id)) { entry in
                    if entry.destructive { Divider() }
                    Button(entry.title, role: entry.destructive ? .destructive : nil) {
                        Task { await consoles.perform(entry.action, on: id) }
                    }
                    .disabled(entry.disabled)
                }
            }
        }
    }
}
