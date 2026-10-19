import RetroArchKit
import SwiftUI

// What the Add Consoles sheet has picked, apart from the view so tests can drive it
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

// Pick the systems you play: only their cores are downloaded
struct AddConsolesSheet: View {
    let center: ConsoleCenter
    @State var choice = AddConsolesChoice()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Consoles").font(.title2.weight(.bold))
            Text("Pick the systems you play. Cartouche downloads only their cores, from libretro.")
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(ConsoleMaker.allCases, id: \.self) { maker in
                        let consoles = ConsoleCatalog.made(by: maker)
                        if !consoles.isEmpty {
                            Text(verbatim: maker.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .accessibilityAddTraits(.isHeader)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
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
                .padding(.vertical, 4)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(choice.addTitle) {
                    let ids = choice.picked
                    dismiss()
                    Task { await center.add(ids) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(choice.picked.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 660, height: 560)
    }
}

struct AddConsoleTile: View {
    let console: Console
    let added: Bool
    let picked: Bool
    let found: Int
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            VStack(alignment: .leading, spacing: 3) {
                ConsoleGlyphView(glyph: console.glyph)
                    .foregroundStyle(picked ? Color.accentColor : Color.secondary)
                Text(verbatim: console.name).font(.callout.weight(.semibold)).lineLimit(2)
                Text(added ? String(localized: "Added") : console.coreName)
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    if console.bios != .none && !added {
                        Text("Needs BIOS")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.orange.opacity(0.18), in: Capsule())
                    }
                    if found > 0 && !added {
                        Text(found == 1 ? String(localized: "1 game found") : String(localized: "\(found) games found"))
                            .font(.caption2)
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 74, alignment: .topLeading)
            .padding(10)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(picked ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(picked ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: picked ? 2 : 0.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(added)
        .opacity(added ? 0.55 : 1)
        .accessibilityAddTraits(picked ? .isSelected : [])
    }
}

// A console in the sidebar, with Add Games and Remove on right-click
struct ConsoleSidebarRow: View {
    let id: String
    let model: LibraryModel
    @Environment(ConsoleCenter.self) private var consoles: ConsoleCenter?

    var body: some View {
        let item = SidebarItem.source(.console(id))
        Label {
            Text(verbatim: LibraryModel.title(item))
        } icon: {
            ConsoleGlyphView(glyph: ConsoleCatalog.console(id)?.glyph ?? .cartridge)
        }
        .badge(model.badge(item).map { Text(verbatim: $0) })
        .tag(item)
        .contextMenu {
            if let consoles {
                ForEach(consoles.menu(for: id)) { entry in
                    if entry.destructive { Divider() }
                    Button(entry.title, role: entry.destructive ? .destructive : nil) {
                        Task { await consoles.perform(entry.action, on: id) }
                    }
                }
            }
        }
    }
}
