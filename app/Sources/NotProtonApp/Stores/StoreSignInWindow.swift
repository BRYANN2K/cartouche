// The sign-in window shows the store's own page, as a browser would. The user
// types their password there, on the store's site; Cartouche only watches the
// addresses the page goes to, and on Epic's last page reads the code it shows.
// The web view keeps no cookies or data once it closes.

import InstallerKit
import SwiftUI
import WebKit

struct StoreSignInWindow: View {
    let center: StoreCenter
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(spacing: 0) {
            content
            Divider()
            HStack(spacing: 8) {
                Image(systemName: "lock.fill").foregroundStyle(.secondary).accessibilityHidden(true)
                Text(footer).font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") {
                    center.cancelSignIn()
                    dismissWindow(id: CartoucheApp.signInWindow)
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(minWidth: 520, minHeight: 640)
        .navigationTitle(title)
        .onChange(of: center.signIn == nil) { _, closed in
            if closed { dismissWindow(id: CartoucheApp.signInWindow) }
        }
        .onDisappear { center.cancelSignIn() }
    }

    private var title: String {
        center.signIn.map { String(localized: "Sign In to \($0.store.name)") } ?? String(localized: "Sign In")
    }

    private var footer: String {
        guard let store = center.signIn?.store else { return "" }
        return String(localized: "This is \(store.name)’s own page. Cartouche keeps only the login token it gives back.")
    }

    @ViewBuilder
    private var content: some View {
        switch center.signIn?.state {
        case .waiting(let page)?:
            StoreWebView(page: page) { url, text in center.reached(url, pageText: text) }
        case .failed(let message)?:
            ContentUnavailableView {
                Label { Text("Sign-in didn’t finish") } icon: { Image(systemName: "exclamationmark.triangle") }
            } description: {
                Text(message)
            } actions: {
                if let store = center.signIn?.store {
                    Button("Try Again") { Task { await center.beginSignIn(store) } }
                }
            }
        default:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

extension View {
    // Lets the store center open the sign-in window from whichever window is open
    func storeSignIn(_ center: StoreCenter) -> some View { modifier(StoreSignInOpener(center: center)) }
}

private struct StoreSignInOpener: ViewModifier {
    let center: StoreCenter
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear {
            center.showSignIn = { [openWindow] in openWindow(id: CartoucheApp.signInWindow) }
        }
    }
}

// A web view with no stored data, reporting each address it reaches. Epic shows
// the code as the text of its last page, so that page's text is read too.
struct StoreWebView: NSViewRepresentable {
    let page: SignInPage
    let reached: @MainActor (URL, String?) -> Bool

    func makeCoordinator() -> Coordinator { Coordinator(page: page, reached: reached) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.load(URLRequest(url: page.url))
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        let page: SignInPage
        let reached: @MainActor (URL, String?) -> Bool
        private var done = false

        init(page: SignInPage, reached: @escaping @MainActor (URL, String?) -> Bool) {
            self.page = page
            self.reached = reached
        }

        // GOG and Amazon hand over the code in the address: the page itself is never loaded
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard !done, let url = action.request.url else { return done ? .cancel : .allow }
            if !page.codeInPage, reached(url, nil) {
                done = true
                return .cancel
            }
            return .allow
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !done, let url = webView.url, page.isCodePage(url) else { return }
            // Only the text of the page the address names, never a form field
            webView.evaluateJavaScript("document.body ? document.body.innerText : ''") { [weak self] value, _ in
                MainActor.assumeIsolated {
                    guard let self, !self.done else { return }
                    if self.reached(url, value as? String) { self.done = true }
                }
            }
        }
    }
}
