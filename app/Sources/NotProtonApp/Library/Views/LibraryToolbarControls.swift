import AppKit
import SwiftUI

// The round controls between the + and the search field
struct LibraryToolbarControls: View {
    @Bindable var model: LibraryModel
    @Environment(StoreCenter.self) private var stores: StoreCenter?

    @ViewBuilder
    var body: some View {
        if model.screen.showsLibraryControls { LibrarySortBall(model: model) }
        if model.screen.showsStoreLink, let link = StoreLink.page(model.selection, stores: stores) {
            StoreLinkBall(link: link, center: stores)
        }
    }
}

// Sort and the Installed filter share one menu; the accent fill says the filter is on
struct LibrarySortBall: View {
    @Bindable var model: LibraryModel

    static func summary(sort: LibrarySort, installedOnly: Bool) -> String {
        let order = String(localized: "Sort · \(sort.title)")
        guard installedOnly else { return order }
        return "\(order) · \(String(localized: "library.filter.installed", defaultValue: "Installed"))"
    }

    var body: some View {
        let summary = Self.summary(sort: model.sort, installedOnly: model.installedOnly)
        Menu {
            Picker(selection: $model.sort) {
                ForEach(LibrarySort.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
            } label: {
                EmptyView()
            }
            .pickerStyle(.inline)
            Divider()
            Toggle(isOn: $model.installedOnly) { Text("Installed Only") }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(RoundGlassStyle(size: 32, on: model.installedOnly))
        .fixedSize()
        .help(Text(verbatim: summary))
        .accessibilityLabel(Text(verbatim: summary))
    }
}

// Where a store page's round button leads
enum StoreLink: Equatable {
    case launcher(GameSource)
    case client(GameSource)
    case web(GameSource, URL)

    @MainActor
    static func page(_ item: SidebarItem, stores: StoreCenter?) -> StoreLink? {
        guard case .source(let source) = item else { return nil }
        switch source {
        case .steam: return .client(.steam)
        case .epic: return .web(.epic, URL(string: "https://store.epicgames.com")!)
        case .gog: return .web(.gog, URL(string: "https://www.gog.com")!)
        case .amazon: return .web(.amazon, URL(string: "https://gaming.amazon.com")!)
        case .ea, .ubisoft: return stores?.signedInLauncher(item).map { .launcher($0) }
        default: return nil
        }
    }

    var source: GameSource {
        switch self {
        case .launcher(let source), .client(let source), .web(let source, _): source
        }
    }
}

struct StoreLinkBall: View {
    let link: StoreLink
    let center: StoreCenter?

    private var title: Text {
        switch link {
        case .launcher: Text("Open Launcher")
        case .client: Text("Open Steam")
        case .web: Text("Open Store")
        }
    }

    private var starting: Bool {
        guard case .launcher(let store) = link else { return false }
        return center?.launcherState(store) == .starting
    }

    var body: some View {
        Button(action: open) {
            if let mark = PlatformMark.source(link.source) {
                PlatformMarkView(mark: mark)
            }
        }
        .buttonStyle(RoundGlassStyle(size: 32))
        .disabled(starting)
        .help(title)
        .accessibilityLabel(title)
    }

    private func open() {
        switch link {
        case .launcher(let store):
            if let center { Task { await center.openLauncher(store) } }
        case .client:
            NSWorkspace.shared.open(SupportPaths.Steam.app)
        case .web(_, let url):
            NSWorkspace.shared.open(url)
        }
    }
}
