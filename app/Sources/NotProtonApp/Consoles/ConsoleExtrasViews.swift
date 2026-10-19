import RetroArchKit
import SwiftUI

struct PlayTogetherRow: View {
    let game: ConsoleGame
    let content: ConsolePanelContent
    let center: ConsoleCenter
    @Binding var showingJoin: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var hosting: Bool {
        if case .host? = center.session.netplay, center.isPlaying(game.id) { return true }
        return false
    }

    var body: some View {
        LabeledContent("Netplay") {
            HStack(spacing: 6) {
                Button("Host") { Task { await center.host(game.id, reduceMotion: reduceMotion) } }
                    .disabled(!content.canPlay)
                Button("Join…") { showingJoin = true }
                    .disabled(center.playing != nil)
            }
            .controlSize(.small)
        }
        if hosting {
            Group {
                if let name = center.extras.netplayNickname {
                    Text("Friends join from RetroArch's lobby, under \(name).")
                } else {
                    Text("Friends join from RetroArch's lobby.")
                }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct NetplayJoinSheet: View {
    let center: ConsoleCenter
    @State private var rooms: NetplayRooms?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Join a Game").font(.title2.weight(.bold))
            Text("Games your friends host in RetroArch's lobby, and on your network, that you have too.")
                .foregroundStyle(.secondary)
            Group {
                if let rooms {
                    if rooms.entries.isEmpty {
                        Text("No friend hosts one of your games right now.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        List(rooms.entries) { entry in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: entry.gameName).fontWeight(.semibold)
                                    Text(verbatim: "\(entry.room.nickname) · \(entry.room.coreName)")
                                        .font(.callout).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if entry.room.origin == .localNetwork {
                                    Text("On your network").font(.caption).foregroundStyle(.secondary)
                                }
                                Button("Join") {
                                    dismiss()
                                    Task { await center.join(entry, reduceMotion: reduceMotion) }
                                }
                                .disabled(entry.room.hasPassword)
                            }
                        }
                    }
                    if rooms.others > 0 {
                        Text("\(rooms.others) other games in the lobby are not in your library.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxHeight: .infinity)
            HStack {
                Button("Refresh") { Task { rooms = nil; rooms = await center.netplayRooms() } }
                    .disabled(rooms == nil)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 480, height: 420)
        .task { rooms = await center.netplayRooms() }
    }
}

// More…'s options: Translate the screen and Coach mode
struct ConsoleOptionsSections: View {
    let game: ConsoleGame
    let center: ConsoleCenter

    static var needsService: String { String(localized: "Needs a translation service, set in Settings") }

    var body: some View {
        Section("Options") {
            Toggle(isOn: Binding(
                get: { center.extras.translates(game) },
                set: { center.extras.setTranslate($0, for: game) }
            )) {
                Text("Translate the screen")
                Text(center.extras.translationService.map { String(localized: "With \($0.host() ?? "")") } ?? Self.needsService)
            }
            if center.extras.translates(game), center.isPlaying(game.id) {
                Button("Translate Now") { Task { await center.translateNow() } }
            }
        }
        Section {
            Toggle(isOn: Binding(
                get: { center.extras.coaches(game) },
                set: { center.extras.setCoach($0, for: game) }
            )) {
                Text("Coach mode")
                Text("An assistant connected to Cartouche reads the game's values and helps when you ask. It never presses a button in Hardcore mode.")
            }
        } header: {
            HStack(spacing: 6) {
                Text("Coach")
                Text("Experimental")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Color.purple.opacity(0.15), in: Capsule())
            }
        }
    }
}

extension View {
    // Local Network's explanation, when the app gave the center a flow
    @ViewBuilder
    func netplayExplanations(_ flow: PermissionFlow?) -> some View {
        if let flow { permissionExplanations(flow) } else { self }
    }
}
