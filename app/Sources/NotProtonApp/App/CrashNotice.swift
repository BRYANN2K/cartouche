// The launch-time check: if a new Cartouche crash report exists since the last
// launch, a quiet banner offers "Show Report" and "Copy Summary". It reads only
// Cartouche's own report names and sends nothing anywhere.

import AppKit
import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class CrashReportCenter {

    private(set) var report: CrashReport?

    // The previous launch's timestamp; a report written after it counts as new
    static let markerKey = "crashReports.lastLaunch"

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let reportsDir: URL
    @ObservationIgnored private let logsDir: URL
    @ObservationIgnored private let home: String
    @ObservationIgnored private let reveal: (URL) -> Void
    @ObservationIgnored private let copy: (String) -> Void
    @ObservationIgnored private var checked = false

    init(
        defaults: UserDefaults = .standard,
        reportsDir: URL = CrashReports.directory,
        logsDir: URL = SupportPaths.logs,
        home: URL = SupportPaths.home,
        reveal: @escaping (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) },
        copy: @escaping (String) -> Void = { text in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    ) {
        self.defaults = defaults
        self.reportsDir = reportsDir
        self.logsDir = logsDir
        self.home = home.path(percentEncoded: false)
        self.reveal = reveal
        self.copy = copy
    }

    // The directory scan and the .ips parse run off the main actor
    func check(now: Date = Date()) async {
        guard !checked else { return }
        checked = true
        let previous = defaults.object(forKey: Self.markerKey) as? TimeInterval
        defaults.set(now.timeIntervalSince1970, forKey: Self.markerKey)
        guard let previous else { return }
        let (dir, logs, home) = (reportsDir, logsDir, home)
        report = await Task.detached(priority: .utility) {
            CrashReports.latest(in: dir, since: Date(timeIntervalSince1970: previous), logs: logs, home: home)
        }.value
        if let name = report?.file.lastPathComponent {
            AppLog.note("crash report found: \(name)")
        }
    }

    func showReport() {
        guard let report else { return }
        reveal(report.file)
        dismiss()
    }

    func copySummary() {
        guard let report else { return }
        copy(report.summary)
        AppLog.note("crash summary copied: \(report.file.lastPathComponent)")
        dismiss()
    }

    func dismiss() {
        report = nil
    }
}

// The mockup's warn banner: an orange mark, a bold line and small pills
struct CrashNoticeBanner: View {
    let center: CrashReportCenter

    var body: some View {
        if let report = center.report {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(report.process) quit unexpectedly last time")
                        .font(.headline)
                    Text("The report stays on this Mac. Copy it to attach it to a bug report.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Button("Show Report") { center.showReport() }
                    .buttonStyle(.pill)
                Button("Copy Summary") { center.copySummary() }
                    .buttonStyle(.pill)
                Button { center.dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                }
                .buttonStyle(RoundGlassStyle(size: 26))
                .help(Text("Dismiss"))
                .accessibilityLabel(Text("Dismiss"))
            }
            .padding(12)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .accessibilityElement(children: .contain)
        }
    }
}
