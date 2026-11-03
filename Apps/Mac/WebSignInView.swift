import SwiftUI
import UsageKit
import WebKit

/// Signs in to claude.ai or chatgpt.com in an isolated web view and captures that session's
/// cookies, so several accounts per provider can be tracked side by side.
struct WebSignInView: View {
    static let windowID = "web-sign-in"

    enum Target: String, Codable, Hashable {
        case claude
        case chatGPT

        var loginURL: URL {
            switch self {
            case .claude: URL(string: "https://claude.ai/login")!
            case .chatGPT: URL(string: "https://chatgpt.com/auth/login")!
            }
        }

        var domain: String {
            switch self {
            case .claude: "claude.ai"
            case .chatGPT: "chatgpt.com"
            }
        }

        var source: CredentialSource {
            switch self {
            case .claude: .claudeWeb
            case .chatGPT: .chatGPTWeb
            }
        }

        /// Runs in the page; resolves to a display name once the session is signed in, else null.
        var probeScript: String {
            switch self {
            case .claude:
                """
                const r = await fetch('/api/organizations', {credentials: 'include'});
                if (!r.ok) return null;
                const orgs = await r.json();
                if (!Array.isArray(orgs) || orgs.length === 0) return null;
                const paid = orgs.find(o => (o.capabilities || []).some(c => c === 'claude_max' || c === 'claude_pro'));
                return ((paid || orgs[0]).name || 'Claude').replace(/'s Organization$/, '');
                """
            case .chatGPT:
                """
                const r = await fetch('/api/auth/session', {credentials: 'include'});
                if (!r.ok) return null;
                const s = await r.json();
                return s && s.accessToken ? ((s.user && s.user.email) || 'ChatGPT') : null;
                """
            }
        }
    }

    let target: Target
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var status = "Sign in with the account you want to track."

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                ProviderBadge(target.source.provider)
                Text(status).font(.callout)
                Spacer()
                Button("Cancel") { dismiss() }
            }
            .padding(10)
            Divider()
            SignInWebView(target: target) { name, cookies in
                status = "Signed in as \(name). Adding account…"
                model.addWebAccount(source: target.source, cookieHeader: cookies, suggestedName: name)
                dismiss()
            }
        }
        .frame(minWidth: 460, minHeight: 600)
    }
}

private struct SignInWebView: NSViewRepresentable {
    let target: WebSignInView.Target
    let onSignedIn: @MainActor (String, String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(target: target, onSignedIn: onSignedIn) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // A fresh, non-persistent store per sign-in keeps accounts from sharing cookies.
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = UsageFetcher.browserUserAgent
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: target.loginURL))
        context.coordinator.start(webView)
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        let target: WebSignInView.Target
        let onSignedIn: @MainActor (String, String) -> Void
        private weak var webView: WKWebView?
        private var timer: Timer?
        private var finished = false

        init(target: WebSignInView.Target, onSignedIn: @escaping @MainActor (String, String) -> Void) {
            self.target = target
            self.onSignedIn = onSignedIn
        }

        func start(_ webView: WKWebView) {
            self.webView = webView
            timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                Task { @MainActor in await self?.probe() }
            }
        }

        func stop() {
            timer?.invalidate()
            timer = nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { await probe() }
        }

        private func probe() async {
            guard !finished, let webView,
                  let host = webView.url?.host(), host == target.domain || host.hasSuffix(".\(target.domain)")
            else { return }

            guard let result = try? await webView.callAsyncJavaScript(target.probeScript, contentWorld: .page),
                  let name = result as? String, !finished
            else { return }

            let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
                .filter { $0.domain == target.domain || $0.domain.hasSuffix(".\(target.domain)") }
            guard !cookies.isEmpty else { return }

            finished = true
            stop()
            onSignedIn(name, CookieHeader.make(from: cookies))
        }
    }
}
