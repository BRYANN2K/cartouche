// Cartouche never draws a password field: the user signs in on the store's own page, in the sign-in window (StoreSignInWindow.swift).

import AppKit
import SwiftUI

struct StorePage: View {
    let source: GameSource
    let center: StoreCenter?

    private var capabilities: StoreCapabilities? { center?.adapter(source)?.capabilities }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Group {
                    if let mark = PlatformMark.source(source) {
                        PlatformMarkView(mark: mark, size: 30)
                    } else {
                        Image(systemName: "gamecontroller").font(.system(size: 30))
                    }
                }
                .foregroundStyle(Color.accentColor)
                .frame(width: 56, height: 56)
                .background(Glass.fill2, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .accessibilityHidden(true)
                if let center, let step = center.launcherStep(source) {
                    LauncherPage(source: source, step: step, center: center)
                } else {
                    clientPage
                }
            }
            .frame(maxWidth: 560, alignment: .leading)
            .padding(.top, 24)
            .padding(.horizontal, 40)
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var clientPage: some View {
        Text("Connect \(source.name)").font(.system(size: 26, weight: .bold)).tracking(-0.5)
        Text(lead)
            .font(.system(size: 14))
            .foregroundStyle(Glass.label2)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
        signInButton
        if case .failed(let message)? = session?.state {
            Text(message).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
        }
        Text("You sign in on \(source.name)’s own page. Cartouche keeps only a login token, in your Keychain.")
            .font(.system(size: 11))
            .foregroundStyle(Glass.label3)
            .fixedSize(horizontal: false, vertical: true)
        if let capabilities {
            Text("What works").groupHeader().padding(.top, 10).padding(.bottom, -10)
            VStack(spacing: 0) {
                capability(Text("Download, update and verify games"), works: true, value: nil)
                Divider().overlay(Glass.separator).padding(.horizontal, 12)
                capability(Text("Cloud saves"), works: capabilities.cloudSaves, value: capabilities.cloudSavesLabel)
                Divider().overlay(Glass.separator).padding(.horizontal, 12)
                capability(Text("Online features"), works: capabilities.online != .notSupported, value: capabilities.onlineLabel)
            }
            .groupBackground()
        }
        Text("Already have games installed?").groupHeader().padding(.top, 10).padding(.bottom, -10)
        VStack(alignment: .leading, spacing: 2) {
            Text("Import games from another launcher or folder")
            Text("Once signed in, from Settings > Accounts: Cartouche checks the game is on your account.")
                .font(.system(size: 12)).foregroundStyle(Glass.label2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .groupBackground()
    }

    private var session: SignInSession? {
        center?.signIn.flatMap { $0.store == source ? $0 : nil }
    }

    private var lead: String {
        guard let client = capabilities?.client else {
            return String(localized: "Sign in once to see your \(source.name) library here. Games then run with the runner you choose.")
        }
        return String(localized: "Sign in once to see your \(source.name) library here. Games download with \(client), an open-source client, and run with the runner you choose.")
    }

    @ViewBuilder
    private var signInButton: some View {
        switch session?.state {
        case .preparing?, .waiting?, .finishing?:
            Button {} label: {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).tint(.white)
                    Text("Waiting for sign-in…")
                }
            }
            .buttonStyle(BigCapsuleStyle())
            .disabled(true)
        default:
            Button("Sign In with \(source.name)…") {
                guard let center else { return }
                Task { await center.beginSignIn(source) }
            }
            .buttonStyle(BigCapsuleStyle())
            .disabled(center == nil)
        }
    }

    private func capability(_ title: Text, works: Bool, value: String?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: works ? "checkmark" : "minus")
                .foregroundStyle(works ? Color.green : Color.secondary)
                .frame(width: 16)
                .accessibilityHidden(true)
            title
            Spacer()
            if let value { Text(value).foregroundStyle(Glass.label2) }
        }
        .padding(12)
        .accessibilityElement(children: .combine)
    }
}

// The label an experimental store carries wherever it is listed.
struct ExperimentalTag: View {
    var compact = false

    private static let ink = Color(light: .init(srgbRed: 0.66, green: 0.3, blue: 0, alpha: 1), dark: .systemOrange)

    var body: some View {
        Text("Experimental")
            .font(.system(size: compact ? 9 : 10, weight: .semibold))
            .foregroundStyle(Self.ink)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, compact ? 4 : 6)
            .padding(.vertical, 1)
            .background(Color.orange.opacity(0.14), in: .capsule)
    }
}

// The same page for a store whose official launcher does the work: one step at a time.
private struct LauncherPage: View {
    let source: GameSource
    let step: LauncherStep
    let center: StoreCenter

    var body: some View {
        HStack(spacing: 10) {
            Text(verbatim: source.name).font(.system(size: 26, weight: .bold)).tracking(-0.5)
            if source.isExperimental { ExperimentalTag() }
        }
        switch step {
        case .install:
            actions { Button("Install \(source.name)") { center.installLauncher(source) } }
        case .signIn:
            actions { signIn }
        case .starting:
            actions { busy(Text("Starting…")) }
        case .waiting:
            actions {
                busy(Text("Waiting for sign-in…"))
            } secondary: {
                Button("Cancel") { center.cancelSignIn() }.buttonStyle(.pill)
            }
        case .installing(let fraction):
            progress(fraction)
        case .failed(let message, let retry):
            Text(message).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            actions {
                switch retry {
                case .install: Button("Try Again") { center.installLauncher(source) }
                case .start: Button("Try Again") { Task { await center.openLauncher(source) } }
                case .signIn: Button("Try Again") { Task { await center.beginSignIn(source) } }
                }
            }
        }
    }

    private var signIn: some View {
        Button("Sign In with \(source.name)…") { Task { await center.beginSignIn(source) } }
    }

    private func busy(_ title: Text) -> some View {
        Button {} label: {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).tint(.white)
                title
            }
        }
        .disabled(true)
    }

    private func progress(_ fraction: Double?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(center.launcherState(source) == .installing ? "Installing" : "Downloading")
                Spacer()
                if let fraction {
                    Text(fraction, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                        .foregroundStyle(Glass.label2)
                }
            }
            .font(.system(size: 13, weight: .medium))
            Group {
                if let fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView()
                }
            }
            .progressViewStyle(.linear)
            .tint(Color.accentColor)
            Button("Cancel") { center.cancelLauncherInstall(source) }
                .buttonStyle(.pill)
                .padding(.top, 4)
        }
        .frame(maxWidth: 360, alignment: .leading)
    }

    private func actions<Primary: View>(@ViewBuilder primary: () -> Primary) -> some View {
        actions(primary: primary) { EmptyView() }
    }

    private func actions<Primary: View, Secondary: View>(@ViewBuilder primary: () -> Primary,
                                                         @ViewBuilder secondary: () -> Secondary) -> some View {
        let primary = primary().buttonStyle(BigCapsuleStyle()), secondary = secondary()
        let store = Button("Open Store", systemImage: "bag") { Task { await center.openStore(source) } }.buttonStyle(.pill)
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { primary; secondary; store }
            VStack(alignment: .leading, spacing: 10) { primary; secondary; store }
        }
    }
}

struct StoreAccountRow: View {
    let source: GameSource
    let center: StoreCenter?
    @State private var importing = false

    var body: some View {
        let connection = center?.connection(source) ?? .notConnected
        let step = center?.launcherStep(source)
        LabeledContent {
            HStack {
                if connection.isSignedIn {
                    if step != nil {
                        Button("Open Launcher") { if let center { Task { await center.openLauncher(source) } } }
                    } else {
                        Button("Import Games…") { importing = true }
                            .help(Text("Add games another launcher installed"))
                    }
                }
                switch connection {
                case .connected:
                    Button("Sign Out") { if let center { Task { await center.signOut(source) } } }
                case .expired:
                    Button("Sign In Again…") { if let center { Task { await center.beginSignIn(source) } } }
                case .waiting:
                    ProgressView().controlSize(.small)
                case .notConnected:
                    switch step {
                    case .install?, .failed(_, retry: .install)?:
                        Button("Install \(source.name)") { center?.installLauncher(source) }
                    case .installing?, .starting?:
                        ProgressView().controlSize(.small)
                    default:
                        Button("Sign In…") { if let center { Task { await center.beginSignIn(source) } } }
                            .disabled(center == nil)
                    }
                }
            }
        } label: {
            HStack(spacing: 10) {
                if let mark = PlatformMark.source(source) {
                    PlatformMarkView(mark: mark).foregroundStyle(.secondary)
                } else {
                    Image(systemName: "gamecontroller").frame(width: 16, height: 16).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading) {
                    HStack(spacing: 6) {
                        Text(verbatim: source.name)
                        if source.isExperimental { ExperimentalTag() }
                    }
                    Text(line(connection)).foregroundStyle(connection.isExpired ? Color.red : Color.secondary)
                }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.folder]) { result in
            if case .success(let folder) = result { center?.importFolder(folder, into: source) }
        }
    }

    private func line(_ connection: StoreConnection) -> String {
        switch connection {
        case .connected(let name):
            StoreConnection.shownAccount(name).isEmpty ? String(localized: "Signed in") : String(localized: "Signed in as \(name)")
        case .expired: String(localized: "Your \(source.name) session expired")
        case .waiting: String(localized: "Waiting for sign-in…")
        case .notConnected: String(localized: "Not connected")
        }
    }
}

