import SwiftUI

struct ConsoleSidebarRow: View {
    let id: String
    @Bindable var model: LibraryModel
    @Environment(ConsoleCenter.self) private var consoles: ConsoleCenter?

    var body: some View {
        let item = SidebarItem.source(.console(id))
        SidebarRow(title: LibraryModel.title(item), badge: model.badge(item), selected: model.selection == item,
                   icon: { BrandMark(badge: .console(id)) }) {
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
