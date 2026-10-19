import SwiftUI

// Placeholder covers while the first import runs
struct LoadingGrid: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: "Steam").font(.title3.weight(.semibold))
                Text("Syncing…").foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 18, alignment: .top)],
                      alignment: .leading, spacing: 20) {
                ForEach(0..<8, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 6) {
                        RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary)
                            .aspectRatio(CoverShape.portrait.aspectRatio, contentMode: .fit)
                        RoundedRectangle(cornerRadius: 3).fill(.quaternary).frame(height: 10)
                        RoundedRectangle(cornerRadius: 3).fill(.quaternary).frame(width: 70, height: 8)
                    }
                }
            }
            .opacity(pulse ? 0.55 : 1)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Loading library"))
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever()) { pulse = true }
        }
    }
}

struct WelcomeView: View {
    let choose: (SidebarItem) -> Void
    let addInstaller: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Bring your games to this Mac").font(.largeTitle.weight(.bold))
            Text("Connect a store or install a Windows game. Everything shows up here, ready to play.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            HStack(spacing: 12) {
                choice(Text(verbatim: "Steam"), Text("Uses Steam Play"), "arrow.down.app") { choose(.source(.steam)) }
                choice(Text(verbatim: "Epic Games"), Text("Sign in"), "person.crop.circle") { choose(.source(.epic)) }
                choice(Text(verbatim: "GOG"), Text("Sign in"), "person.crop.circle") { choose(.source(.gog)) }
                choice(Text("Windows Installer"), Text("setup.exe and .bin"), "shippingbox") { addInstaller() }
            }
            .padding(.top, 8)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func choice(_ title: Text, _ detail: Text, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.title2).foregroundStyle(Color.accentColor)
                title.font(.headline)
                detail.font(.caption).foregroundStyle(.secondary)
            }
            .frame(width: 130, height: 96)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .groupBackground()
    }
}

// The Steam source when Steam is not on this Mac
struct SteamInstallView: View {
    @Bindable var setup: SteamSetup
    let locate: () -> URL?
    let openSteam: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Image(systemName: "arrow.down.app")
                    .font(.system(size: 30))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 56, height: 56)
                    .groupBackground(radius: 14)
                    .accessibilityHidden(true)
                Text(setup.stage == .signIn ? "Sign in to Steam" : "Install Steam")
                    .font(.largeTitle.weight(.bold))
                Text(setup.stage == .signIn
                     ? "Steam is installed. Sign in once in Steam. Your library then shows up here, and Windows games run through Steam Play."
                     : "Your Steam library needs the Mac version of Steam. Windows games then run through Steam Play, with the runners you set up here.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                mainButton
                if case .failed(let message) = setup.stage {
                    Text(message).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                if setup.stage != .signIn {
                    Text("Downloads the official installer from Valve and moves Steam to Applications.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("Other ways").font(.headline).padding(.top, 10)
                    VStack(spacing: 0) {
                        if setup.homebrew != nil {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Install with Homebrew")
                                    Text(verbatim: SteamSetup.homebrewCommand)
                                        .font(.callout.monospaced())
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                                Spacer()
                                if setup.stage == .installingWithHomebrew {
                                    ProgressView().controlSize(.small)
                                }
                                Button("Run") { Task { await setup.installWithHomebrew() } }
                                    .disabled(setup.isWorking)
                            }
                            .padding(12)
                            Divider().padding(.horizontal, 12)
                        }
                        HStack {
                            Text("Steam is somewhere else")
                            Spacer()
                            Button("Locate Steam…") {
                                if let app = locate() { setup.locate(app) }
                            }
                            .disabled(setup.isWorking)
                        }
                        .padding(12)
                    }
                    .groupBackground()
                }
            }
            .frame(maxWidth: 520, alignment: .leading)
            .padding(40)
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var mainButton: some View {
        switch setup.stage {
        case .signIn:
            Button("Open Steam to Sign In", action: openSteam)
                .controlSize(.large)
                .prominentButton()
        case .downloading:
            Button {} label: {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Downloading Steam…")
                }
            }
            .controlSize(.large)
            .prominentButton()
            .disabled(true)
        default:
            Button("Download Steam") { Task { await setup.downloadSteam() } }
                .controlSize(.large)
                .prominentButton()
                .disabled(setup.isWorking)
        }
    }

    static func chooseSteam() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(filePath: "/Applications")
        panel.message = String(localized: "Choose the Steam app.")
        return panel.runModal() == .OK ? panel.url : nil
    }
}

// A store that is not connected yet. Store sign-in arrives with P10.
struct SignInView: View {
    let source: GameSource

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "person.crop.circle")
                .font(.system(size: 30))
                .foregroundStyle(Color.accentColor)
                .frame(width: 56, height: 56)
                .groupBackground(radius: 14)
                .accessibilityHidden(true)
            Text("Connect \(source.name)").font(.largeTitle.weight(.bold))
            Text("Sign in once to see your \(source.name) library here. Games then run with the runner you choose.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Sign In with \(source.name)…") {}
                .controlSize(.large)
                .prominentButton()
                .disabled(true)
            Text("\(source.name) support comes in a later version of Cartouche. You will sign in on \(source.name)’s own page, and Cartouche will keep only a login token, in your Keychain.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 520, alignment: .leading)
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

struct NoResultsView: View {
    let query: String
    let clear: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label { Text("No games match “\(query)”") } icon: { Image(systemName: "magnifyingglass") }
        } description: {
            Text("Check the spelling, or connect another store.")
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
            ContentUnavailableView {
                Label { Text("No favorites yet") } icon: { Image(systemName: "star") }
            } description: {
                Text("Click the star on a game to add it here.")
            }
        case .emptySource(let source) where source.isConsole:
            ContentUnavailableView {
                Label { Text("No \(source.name) games yet") } icon: { Image(systemName: "opticaldisc") }
            } description: {
                Text("Add your own game dumps with Add Games, or put them in a watched folder.")
            } actions: {
                Button("Add Games…", action: addGames)
            }
        case .emptySource(.installer):
            ContentUnavailableView {
                Label { Text("No Windows installers yet") } icon: { Image(systemName: "shippingbox") }
            } description: {
                Text("Drop a setup.exe or a game folder on Add Games to install it.")
            } actions: {
                Button("Add Games…", action: addGames)
            }
        case .emptySource(let source):
            ContentUnavailableView {
                Label { Text("No \(source.name) games yet") } icon: { Image(systemName: "gamecontroller") }
            } description: {
                Text("Games you own show up here once \(source.name) is running and signed in.")
            }
        case .failed(let message):
            ContentUnavailableView {
                Label { Text("Cartouche couldn’t read your library") } icon: { Image(systemName: "exclamationmark.triangle") }
            } description: {
                Text(message)
            } actions: {
                Button("Try Again", action: retry)
            }
        default:
            EmptyView()
        }
    }
}
