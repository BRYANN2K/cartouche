import SwiftUI

struct LoadingGrid: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shine = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: "Steam").font(.system(size: 13, weight: .bold))
                Text("Syncing…").font(.system(size: 12, weight: .medium)).foregroundStyle(Glass.label3)
            }
            .padding(.horizontal, 4)
            .padding(.top, 6)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 16, alignment: .top)],
                      alignment: .leading, spacing: 22) {
                ForEach(0..<8, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 0) {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .aspectRatio(CoverShape.portrait.aspectRatio, contentMode: .fit)
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .frame(height: 10)
                            .padding(.trailing, 28)
                            .padding(.top, 10)
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .frame(width: 70, height: 10)
                            .padding(.top, 6)
                    }
                    .foregroundStyle(Glass.fill)
                }
            }
            .overlay {
                // The skeleton's sheen sweeping across, a still fill under Reduce Motion
                if !reduceMotion {
                    GeometryReader { proxy in
                        LinearGradient(colors: [.white.opacity(0), .white.opacity(0.06), .white.opacity(0)],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(width: proxy.size.width / 2)
                            .offset(x: shine ? proxy.size.width : -proxy.size.width / 2)
                    }
                    .allowsHitTesting(false)
                    .onAppear {
                        withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) { shine = true }
                    }
                }
            }
            .clipped()
        }
        .padding(EdgeInsets(top: 8, leading: 12, bottom: 24, trailing: 16))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Loading library"))
    }
}

// The mockup's .empty-lib: a quiet symbol, a bold line, a secondary line and one pill action
struct EmptyState<Icon: View, Actions: View>: View {
    let title: Text
    let message: Text
    @ViewBuilder let icon: () -> Icon
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(spacing: 0) {
            icon()
                .font(.system(size: 30, weight: .light))
                .frame(height: 32)
                .foregroundStyle(Glass.label3)
                .padding(.bottom, 10)
                .accessibilityHidden(true)
            title.font(.system(size: 15, weight: .bold))
                .multilineTextAlignment(.center)
                .padding(.bottom, 4)
            message.font(.system(size: 13))
                .foregroundStyle(Glass.label2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            actions()
                .buttonStyle(.pill)
                .padding(.top, 12)
        }
        .padding(.horizontal, 20)
        .padding(.top, 60)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .contain)
    }
}

extension EmptyState where Actions == EmptyView {
    init(title: Text, message: Text, @ViewBuilder icon: @escaping () -> Icon) {
        self.init(title: title, message: message, icon: icon, actions: { EmptyView() })
    }
}

struct WelcomeView: View {
    let choose: (SidebarItem) -> Void
    let addInstaller: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 52, weight: .ultraLight))
                    .foregroundStyle(Glass.label3)
                    .frame(height: 120)
                    .accessibilityHidden(true)
                Text("Bring your games to this Mac")
                    .font(.system(size: 28, weight: .bold))
                    .tracking(-0.7)
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 8)
                Text("Connect a store or install a Windows game. Everything shows up here, ready to play.")
                    .font(.system(size: 14))
                    .foregroundStyle(Glass.label2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                    .padding(.bottom, 26)
                HStack(spacing: 10) {
                    choice(Text(verbatim: "Steam"), Text("Uses Steam Play"), mark: .steam) { choose(.source(.steam)) }
                    choice(Text(verbatim: "Epic Games"), Text("Sign in"), mark: .epic) { choose(.source(.epic)) }
                    choice(Text(verbatim: "GOG"), Text("Sign in"), mark: .gog) { choose(.source(.gog)) }
                    choice(Text("Windows Installer"), Text("setup.exe and .bin"), symbol: "shippingbox") { addInstaller() }
                }
            }
            .frame(maxWidth: 560)
            .padding(.top, 30)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity)
        }
    }

    private func choice(_ title: Text, _ detail: Text, mark: PlatformMark? = nil, symbol: String? = nil,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Group {
                    if let mark { PlatformMarkView(mark: mark, size: 26) }
                    else if let symbol { Image(systemName: symbol).font(.system(size: 22)) }
                }
                .foregroundStyle(Color.accentColor)
                .frame(height: 26)
                .padding(.bottom, 4)
                title.font(.system(size: 13, weight: .bold)).multilineTextAlignment(.center)
                detail.font(.system(size: 11)).foregroundStyle(Glass.label2)
            }
            .padding(.vertical, 16)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 110)
            .contentShape(.rect)
        }
        .buttonStyle(ChoiceButtonStyle())
    }
}

private struct ChoiceButtonStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(hovering ? Glass.fill2 : Glass.fill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(duration: 0.2, bounce: 0), value: configuration.isPressed)
            .onHover { hovering = $0 }
    }
}

struct SteamInstallView: View {
    @Bindable var setup: SteamSetup
    let locate: () -> URL?
    let openSteam: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PlatformMarkView(mark: .steam, size: 30)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 56, height: 56)
                    .background(Glass.fill2, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .accessibilityHidden(true)
                Text(setup.stage == .signIn ? "Sign in to Steam" : "Install Steam")
                    .font(.system(size: 26, weight: .bold))
                    .tracking(-0.5)
                Text(setup.stage == .signIn
                     ? "Steam is installed. Sign in once in Steam. Your library then shows up here, and Windows games run through Steam Play."
                     : "Your Steam library needs the Mac version of Steam. Windows games then run through Steam Play, with the runners you set up here.")
                    .font(.system(size: 14))
                    .foregroundStyle(Glass.label2)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                mainButton
                if case .failed(let message) = setup.stage {
                    Text(message).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                if setup.stage != .signIn {
                    Text("Downloads the official installer from Valve and moves Steam to Applications.")
                        .font(.system(size: 11))
                        .foregroundStyle(Glass.label3)
                    Text("Other ways").groupHeader().padding(.top, 10).padding(.bottom, -10)
                    VStack(spacing: 0) {
                        if setup.homebrew != nil {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Install with Homebrew")
                                    Text(verbatim: SteamSetup.homebrewCommand)
                                        .font(.system(size: 12).monospaced())
                                        .foregroundStyle(Glass.label2)
                                        .textSelection(.enabled)
                                }
                                Spacer()
                                if setup.stage == .installingWithHomebrew {
                                    ProgressView().controlSize(.small)
                                }
                                Button("Run") { Task { await setup.installWithHomebrew() } }
                                    .buttonStyle(.pill)
                                    .disabled(setup.isWorking)
                            }
                            .padding(12)
                            Divider().overlay(Glass.separator).padding(.horizontal, 12)
                        }
                        HStack {
                            Text("Steam is somewhere else")
                            Spacer()
                            Button("Locate Steam…") {
                                if let app = locate() { setup.locate(app) }
                            }
                            .buttonStyle(.pill)
                            .disabled(setup.isWorking)
                        }
                        .padding(12)
                    }
                    .groupBackground()
                }
            }
            .frame(maxWidth: 560, alignment: .leading)
            .padding(.top, 24)
            .padding(.horizontal, 40)
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var mainButton: some View {
        Group {
            switch setup.stage {
            case .signIn:
                Button("Open Steam to Sign In", action: openSteam)
            case .downloading:
                Button {} label: {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small).tint(.white)
                        Text("Downloading Steam…")
                    }
                }
                .disabled(true)
            default:
                Button("Download Steam") { Task { await setup.downloadSteam() } }
                    .disabled(setup.isWorking)
            }
        }
        .buttonStyle(BigCapsuleStyle())
    }

    static func chooseSteam() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(filePath: "/Applications")
        panel.message = String(localized: "Choose the Steam app.")
        return panel.runModal() == .OK ? panel.url : nil
    }
}

struct SignInView: View {
    let source: GameSource
    @Environment(StoreCenter.self) private var stores: StoreCenter?

    var body: some View {
        StorePage(source: source, center: stores)
    }
}

struct NoResultsView: View {
    let query: String
    let clear: () -> Void

    var body: some View {
        EmptyState(title: Text("No games match “\(query)”"),
                   message: Text("Check the spelling, or connect another store.")) {
            Image(systemName: "magnifyingglass")
        } actions: {
            Button("Clear Search", action: clear)
        }
    }
}

struct EmptyLibraryView: View {
    let screen: LibraryScreen
    let addGames: () -> Void
    let retry: () -> Void

    var body: some View {
        switch screen {
        case .emptyFavorites:
            EmptyState(title: Text("No favorites yet"), message: Text("Click the star on a game to add it here.")) {
                Image(systemName: "star")
            }
        case .emptySource(let source) where source.isConsole:
            EmptyState(title: Text("No \(source.name) games yet"),
                       message: Text("Add your own game dumps with Add Games, or put them in a watched folder.")) {
                if case .console(let id) = source { ConsoleMarkView(id: id, size: 30) }
            } actions: {
                Button("Add Games…", action: addGames)
            }
        case .emptySource(.installer):
            EmptyState(title: Text("No Windows installers yet"),
                       message: Text("Drop a setup.exe or a game folder on Add Games to install it.")) {
                Image(systemName: "shippingbox")
            } actions: {
                Button("Add Games…", action: addGames)
            }
        case .emptySource(let source):
            EmptyState(title: Text("No \(source.name) games yet"),
                       message: source == .steam
                        ? Text("Keep Steam signed in to import your library automatically. If it stays empty, update the integration in Settings > Steam.")
                        : Text("Games you own show up here once \(source.name) is running and signed in.")) {
                if let mark = PlatformMark.source(source) {
                    PlatformMarkView(mark: mark, size: 30)
                } else {
                    Image(systemName: "gamecontroller")
                }
            } actions: {
                if source == .steam {
                    Button("Open Steam") { NSWorkspace.shared.open(SupportPaths.Steam.app) }
                }
            }
        default:
            EmptyView()
        }
    }
}
