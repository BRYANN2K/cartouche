// The store screens: a store's page before it is connected, its row in
// Settings > Accounts, and its download in the sidebar's activity slot.
// Cartouche never draws a password field: the user signs in on the store's own
// page, in the sign-in window (StoreSignInWindow.swift).

import AppKit
import SwiftUI

// A store that is not connected yet: what signing in does, and what works
struct StorePage: View {
    let source: GameSource
    let center: StoreCenter?

    private var capabilities: StoreCapabilities? { center?.adapter(source)?.capabilities }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 30))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 56, height: 56)
                    .groupBackground(radius: 14)
                    .accessibilityHidden(true)
                Text("Connect \(source.name)").font(.largeTitle.weight(.bold))
                Text(lead)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                signInButton
                if case .failed(let message)? = session?.state {
                    Text(message).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                Text("You sign in on \(source.name)’s own page. Cartouche keeps only a login token, in your Keychain.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let capabilities {
                    Text("What works").font(.headline).padding(.top, 10)
                    VStack(spacing: 0) {
                        capability(Text("Download, update and verify games"), works: capabilities.downloads, value: nil)
                        Divider().padding(.horizontal, 12)
                        capability(Text("Cloud saves"), works: capabilities.cloudSaves, value: capabilities.cloudSavesLabel)
                        Divider().padding(.horizontal, 12)
                        capability(Text("Online features"), works: capabilities.online != .notSupported, value: capabilities.onlineLabel)
                    }
                    .groupBackground()
                }
                Text("Already have games installed?").font(.headline).padding(.top, 10)
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Import games from another launcher or folder")
                        Text("Sign in first: Cartouche checks the game is on your account.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Choose Folder…") {}.disabled(true)
                }
                .padding(12)
                .groupBackground()
            }
            .frame(maxWidth: 520, alignment: .leading)
            .padding(40)
            .frame(maxWidth: .infinity)
        }
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
                    ProgressView().controlSize(.small)
                    Text("Waiting for sign-in…")
                }
            }
            .controlSize(.large)
            .prominentButton()
            .disabled(true)
        default:
            Button("Sign In with \(source.name)…") {
                guard let center else { return }
                Task { await center.beginSignIn(source) }
            }
            .controlSize(.large)
            .prominentButton()
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
            if let value { Text(value).foregroundStyle(.secondary) }
        }
        .padding(12)
        .accessibilityElement(children: .combine)
    }
}

// One store in Settings > Accounts
struct StoreAccountRow: View {
    let source: GameSource
    let center: StoreCenter?
    @State private var importing = false

    var body: some View {
        let connection = center?.connection(source) ?? .notConnected
        LabeledContent {
            HStack {
                if connection.isSignedIn {
                    Button("Import Games…") { importing = true }
                        .help(Text("Add games another launcher installed"))
                }
                switch connection {
                case .connected:
                    Button("Sign Out") { if let center { Task { await center.signOut(source) } } }
                case .expired:
                    Button("Sign In Again…") { if let center { Task { await center.beginSignIn(source) } } }
                case .waiting:
                    ProgressView().controlSize(.small)
                case .notConnected:
                    Button("Sign In…") { if let center { Task { await center.beginSignIn(source) } } }
                        .disabled(center == nil)
                }
            }
        } label: {
            Text(verbatim: source.name)
            Text(line(connection)).foregroundStyle(connection.isExpired ? Color.red : Color.secondary)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.folder]) { result in
            if case .success(let folder) = result { center?.importFolder(folder, into: source) }
        }
    }

    private func line(_ connection: StoreConnection) -> String {
        switch connection {
        case .connected(let name): name.isEmpty ? String(localized: "Signed in") : String(localized: "Signed in as \(name)")
        case .expired: String(localized: "Your \(source.name) session expired")
        case .waiting: String(localized: "Waiting for sign-in…")
        case .notConnected: String(localized: "Not connected")
        }
    }
}

// The sidebar's activity slot while a store game downloads
struct StoreActivityRow: View {
    let center: StoreCenter
    let model: LibraryModel

    var body: some View {
        if let activity = center.activity {
            HStack(spacing: 10) {
                ZStack {
                    Circle().stroke(.quaternary, lineWidth: 3)
                    Circle().trim(from: 0, to: activity.fraction)
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: "\(activity.label) \(Int((activity.fraction * 100).rounded()))%")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    Text(verbatim: activity.title).font(.callout.weight(.semibold)).lineLimit(1)
                }
                Spacer(minLength: 4)
                Button {
                    if let job = center.jobs.first(where: { $0.gameID == activity.gameID && $0.phase == .running }) { center.stop(job) }
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help(Text("Stop"))
                .accessibilityLabel(Text("Stop"))
            }
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
            .contentShape(Rectangle())
            .onTapGesture { model.select(activity.gameID) }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("\(activity.title), \(activity.label)"))
            .accessibilityValue(Text(verbatim: "\(Int((activity.fraction * 100).rounded()))%"))
        }
    }
}
