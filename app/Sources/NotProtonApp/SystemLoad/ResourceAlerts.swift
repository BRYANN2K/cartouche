import AppKit
import SwiftUI

@MainActor
final class AppIcons {
    private var cache: [String: NSImage] = [:]
    private let generic = NSWorkspace.shared.icon(for: .unixExecutable)

    func icon(for row: ResourceUsage) -> NSImage {
        guard let path = row.bundlePath else { return generic }
        if let icon = cache[path] { return icon }
        let icon = NSWorkspace.shared.icon(forFile: path)
        cache[path] = icon
        return icon
    }
}

// Shown in the library after a game started on a busy Mac; never in the way of the game.
struct ResourceAlertBanner: View {
    let monitor: ResourceMonitor

    var body: some View {
        if let alert = monitor.alert {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "gauge.with.dots.needle.67percent")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Your Mac is busy, so the game may not run well")
                        .font(.headline)
                    Text(ResourceAlertText.detail(alert))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Button("Show Resources") {
                    monitor.showWindow()
                    monitor.alert = nil
                }
                .buttonStyle(.pill)
                Button { monitor.alert = nil } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                }
                .buttonStyle(RoundGlassStyle(size: 26))
                .help(Text("Dismiss"))
                .accessibilityLabel(Text("Dismiss"))
            }
            .padding(12)
            .groupBackground(radius: Glass.panelRadius, tint: .orange)
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .accessibilityElement(children: .contain)
        }
    }
}

enum ResourceAlertText {
    static let category = "resources-load"
    static let showAction = "show-resources"

    static func detail(_ verdict: LoadVerdict) -> String {
        let reasons = verdict.reasons.map(\.text).joined(separator: " ")
        guard !verdict.top.isEmpty else { return reasons }
        let names = verdict.top.map(\.name).formatted(.list(type: .and))
        return reasons + " " + String(localized: "Using the most: \(names).")
    }

    static func notification(_ verdict: LoadVerdict) -> NotificationSpec {
        NotificationSpec(identifier: "resources-load", title: String(localized: "Your Mac is busy"),
                         body: detail(verdict), category: category, action: showAction,
                         actionTitle: String(localized: "Show Resources"), userInfo: [:])
    }
}
