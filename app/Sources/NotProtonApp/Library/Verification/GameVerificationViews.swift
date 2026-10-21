import SwiftUI

struct GameVerificationRow: View {
    let game: Game
    @Environment(\.gameVerification) private var verification

    var body: some View {
        let status = verification?.status(for: game.id) ?? .notVerified
        VStack(alignment: .leading, spacing: 7) {
            Label(status.title, systemImage: status == .notVerified ? "shield" : "checkmark.shield")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Glass.label2)
            Text(status.detail)
                .font(.system(size: 11))
                .foregroundStyle(Glass.label2)
                .fixedSize(horizontal: false, vertical: true)
            if let progress = verification?.progress(for: game.id) {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Verifying files…").font(.system(size: 12, weight: .medium))
                        ProgressView(value: progress.fraction)
                            .accessibilityLabel(Text("Verification progress"))
                        Text(verbatim: progress.file)
                            .font(.system(size: 11))
                            .foregroundStyle(Glass.label2)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Button("Stop") { verification?.stop(gameID: game.id) }
                        .buttonStyle(.pill)
                }
            }
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
    }
}

struct GameVerificationMismatchSheet: View {
    let mismatch: GameVerificationMismatch
    let verification: any GameVerificationPresenting

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SheetHeader(title: Text("Some files don’t match"),
                        message: Text("Retry with the standard method to restore the expected files. Keeping them does not verify this game."))
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(mismatch.files.enumerated()), id: \.offset) { _, file in
                        Text(verbatim: file)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(12)
            }
            .frame(maxHeight: 180)
            .groupBackground()
            Text("Keep Anyway is an advanced option. Mismatched files are recorded in the log.")
                .font(.system(size: 11))
                .foregroundStyle(Glass.label2)
            HStack(spacing: 8) {
                Button("Cancel") { verification.cancelMismatch(gameID: mismatch.gameID) }
                    .buttonStyle(.sheet)
                    .keyboardShortcut(.cancelAction)
                Spacer(minLength: 0)
                Button("Keep Anyway") { verification.keepAnyway(gameID: mismatch.gameID) }
                    .buttonStyle(.sheet)
                Button("Retry with the Standard Method") { verification.retryStandard(gameID: mismatch.gameID) }
                    .buttonStyle(.sheetProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 620)
        .interactiveDismissDisabled()
    }
}
