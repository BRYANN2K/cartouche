
import SwiftUI

struct PermissionExplanationView: View {

    let explanation: PermissionExplanation
    let onNotNow: () -> Void
    let onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(explanation.title)
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text(explanation.reason)
                .fixedSize(horizontal: false, vertical: true)
            if let relaunch = explanation.relaunch {
                Text(relaunch)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Not Now", action: onNotNow)
                    .keyboardShortcut(.cancelAction)
                Button("Continue", action: onContinue)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 6)
        }
        .padding(20)
        .frame(width: 380)
    }
}

extension View {
    func permissionExplanations(_ flow: PermissionFlow) -> some View {
        sheet(item: Binding(
            get: { flow.asking },
            set: { if $0 == nil { flow.notNow() } }
        )) { ask in
            PermissionExplanationView(
                explanation: ask.explanation,
                onNotNow: { flow.notNow() },
                onContinue: { Task { await flow.confirm() } }
            )
        }
    }
}
