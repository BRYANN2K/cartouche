import SwiftUI

// Settings > Consoles, the part P14 adds: the RetroAchievements account,
// saves in iCloud Drive, the translation service and the netplay name
struct ConsoleExtrasSections: View {

    @Bindable var extras: ConsoleExtras
    @State private var signingIn = false
    @State private var settingService = false

    var body: some View {
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: "RetroAchievements")
                    Text(extras.username.map { String(localized: "Signed in as \($0)", bundle: .module) }
                         ?? String(localized: "Not signed in", bundle: .module))
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if extras.username != nil {
                    Button { extras.signOut() } label: { Text("Sign Out", bundle: .module) }
                } else {
                    Button { signingIn = true } label: { Text("Sign In…", bundle: .module) }
                }
            }
            LabeledContent {
                TextField(text: Binding(get: { extras.netplayNickname ?? "" }, set: { extras.setNetplayNickname($0) }),
                          prompt: Text("RetroArch's default", bundle: .module)) {
                    Text("Netplay name", bundle: .module)
                }
                .labelsHidden()
                .frame(maxWidth: 180)
                .multilineTextAlignment(.trailing)
            } label: {
                Text("Netplay name", bundle: .module)
                Text("Shown to friends in RetroArch's lobby", bundle: .module)
            }
        } header: {
            Text("Accounts", bundle: .module)
        }

        Section {
            Toggle(isOn: Binding(get: { extras.cloudSaves }, set: { extras.setCloudSaves($0) })) {
                Text("Save states to iCloud Drive", bundle: .module)
                Text("Saves and states follow you to your other Macs, in iCloud Drive's Cartouche folder.", bundle: .module)
            }
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Translation service", bundle: .module)
                    Text(extras.translationService.map { String(localized: "Used by Translate the screen: \($0.absoluteString)", bundle: .module) }
                         ?? String(localized: "Used by Translate the screen. Not set.", bundle: .module))
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button { settingService = true } label: { Text("Set Up…", bundle: .module) }
            }
        } header: {
            Text("Defaults", bundle: .module)
        } footer: {
            if let problem = extras.problem { Text(problem).foregroundStyle(.red) }
        }
        .sheet(isPresented: $signingIn) { SignInSheet(extras: extras) }
        .sheet(isPresented: $settingService) { TranslationServiceSheet(extras: extras) }
    }
}

private struct SignInSheet: View {
    let extras: ConsoleExtras
    @State private var username = ""
    @State private var password = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sign In to RetroAchievements", bundle: .module).font(.title3.weight(.semibold))
            Text("Your password goes to RetroAchievements once. Cartouche keeps only the sign-in token, in your keychain.", bundle: .module)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField(text: $username) { Text("Username", bundle: .module) }
                .textContentType(.username)
            SecureField(text: $password) { Text("Password", bundle: .module) }
                .textContentType(.password)
            if let problem = extras.problem { Text(problem).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button { dismiss() } label: { Text("Cancel", bundle: .module) }
                    .keyboardShortcut(.cancelAction)
                Button {
                    Task {
                        await extras.signIn(username: username, password: password)
                        password = ""
                        if extras.username != nil { dismiss() }
                    }
                } label: { Text("Sign In", bundle: .module) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(username.isEmpty || password.isEmpty || extras.working)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

private struct TranslationServiceSheet: View {
    let extras: ConsoleExtras
    @State private var address = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Translation Service", bundle: .module).font(.title3.weight(.semibold))
            Text("RetroArch sends a picture of the game to this address and shows the translation it gets back. Use a service you trust: it sees your screen.", bundle: .module)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField(text: $address) { Text("Address", bundle: .module) }
            HStack {
                Button { extras.setTranslationService(""); dismiss() } label: { Text("Remove", bundle: .module) }
                    .disabled(extras.translationService == nil)
                Spacer()
                Button { dismiss() } label: { Text("Cancel", bundle: .module) }
                    .keyboardShortcut(.cancelAction)
                Button {
                    extras.setTranslationService(address)
                    dismiss()
                } label: { Text("Save", bundle: .module) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(TranslationSetup.service(address) == nil)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { address = extras.translationService?.absoluteString ?? "" }
    }
}
