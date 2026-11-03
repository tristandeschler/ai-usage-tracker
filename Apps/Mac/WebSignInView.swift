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
            case .claude: .claudeWeb(organizationID: nil)
            case .chatGPT: .chatGPTWeb
            }
        }

        /// Cookies worth keeping: the login itself plus Cloudflare's, which some requests need.
        /// Analytics and preference cookies are dropped.
        func isEssential(_ cookie: HTTPCookie) -> Bool {
            let cloudflare = ["cf_clearance", "__cf_bm", "_cfuvid", "__cflb"]
            if cloudflare.contains(cookie.name) { return true }
            switch self {
            case .claude: return ["sessionKey", "routingHint", "lastActiveOrg"].contains(cookie.name)
            case .chatGPT: return cookie.name.hasPrefix("__Secure-next-auth.session-token")
            }
        }

        /// The cookie that holds the login, for the paste-it-yourself fallback.
        var sessionCookie: String {
            switch self {
            case .claude: "sessionKey"
            case .chatGPT: "__Secure-next-auth.session-token"
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
    @State private var browser = BrowserController()
    @State private var status = "Sign in with the account you want to track."
    @State private var failed = false
    @State private var link = ""
    @State private var showPaste = false
    /// Set when one login reaches several Claude organizations and the user must pick.
    @State private var pendingSession: PendingSession?
    @State private var selectedOrganizations: Set<String> = []

    struct PendingSession {
        var cookies: String
        var userAgent: String?
        var organizations: [ClaudeOrganization]
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    ProviderBadge(target.source.provider)
                    Text(status)
                        .font(.callout)
                        .foregroundStyle(failed ? .red : .primary)
                        .lineLimit(2)
                    Spacer()
                    Button("Paste Session Key…") { showPaste = true }
                    Button("Cancel") { dismiss() }
                }
                HStack {
                    TextField("Got a sign-in link by email? Paste it here instead of clicking it", text: $link)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(openLink)
                    Button("Open", action: openLink)
                        .disabled(URL(string: link.trimmingCharacters(in: .whitespaces))?.host() == nil)
                }
                Text("Signing in by email? Don't click the link. That signs in your browser, not this window. Copy it and paste it above instead. If Google won't let you in here, use email.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            Divider()
            SignInWebView(target: target, controller: browser) { name, cookies, userAgent in
                await finish(cookies: cookies, userAgent: userAgent, name: name)
            }
            .overlay {
                if let pendingSession { organizationPicker(pendingSession) }
            }
        }
        .frame(minWidth: 520, minHeight: 640)
        .sheet(isPresented: $showPaste) {
            PasteSessionSheet(target: target) { cookies in
                await finish(cookies: cookies, userAgent: nil, name: nil)
            }
        }
    }

    private func openLink() {
        guard let url = URL(string: link.trimmingCharacters(in: .whitespaces)), url.host() != nil else { return }
        browser.webView?.load(URLRequest(url: url))
        link = ""
    }

    /// Returns an error message when the session doesn't work, so the caller can stay open.
    @discardableResult
    private func finish(cookies: String, userAgent: String?, name: String?) async -> String? {
        status = "Checking \(target.domain) usage…"
        failed = false

        guard target == .claude else {
            return await add(source: target.source, cookies: cookies, userAgent: userAgent, name: name)
        }

        let organizations: [ClaudeOrganization]
        do {
            organizations = try await model.claudeOrganizations(cookieHeader: cookies, userAgent: userAgent)
        } catch {
            return fail((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
        if organizations.count == 1, let org = organizations.first {
            return await add(source: .claudeWeb(organizationID: org.id), cookies: cookies, userAgent: userAgent, name: org.displayName)
        }
        selectedOrganizations = Set(organizations.filter { !model.isTracking(claudeOrganization: $0.id) }.map(\.id))
        pendingSession = PendingSession(cookies: cookies, userAgent: userAgent, organizations: organizations)
        status = "This login has \(organizations.count) Claude accounts. Pick the ones to track."
        return nil
    }

    private func add(source: CredentialSource, cookies: String, userAgent: String?, name: String?) async -> String? {
        if let error = await model.addWebAccount(source: source, cookieHeader: cookies, userAgent: userAgent, suggestedName: name) {
            return fail(error)
        }
        return nil
    }

    private func fail(_ error: String) -> String {
        status = "Couldn't read usage: \(error)"
        failed = true
        return error
    }

    private func trackSelected(_ session: PendingSession) async {
        for org in session.organizations where selectedOrganizations.contains(org.id) {
            status = "Adding \(org.displayName)…"
            guard await add(
                source: .claudeWeb(organizationID: org.id), cookies: session.cookies,
                userAgent: session.userAgent, name: org.displayName
            ) == nil else { return }
        }
        dismiss()
    }

    private func organizationPicker(_ session: PendingSession) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Which accounts do you want to track?")
                .font(.headline)
            Text("Your email is on more than one Claude plan, and each one has its own limits.")
                .font(.callout)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(session.organizations) { org in
                    let tracked = model.isTracking(claudeOrganization: org.id)
                    Toggle(isOn: Binding(
                        get: { selectedOrganizations.contains(org.id) },
                        set: { on in
                            if on { selectedOrganizations.insert(org.id) } else { selectedOrganizations.remove(org.id) }
                        }
                    )) {
                        HStack {
                            Text(org.displayName)
                            if let plan = org.plan {
                                Text(plan)
                                    .font(.caption.weight(.medium))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(.quaternary, in: Capsule())
                            }
                            if tracked {
                                Text("Already tracked").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .disabled(tracked)
                }
            }
            HStack {
                Spacer()
                Button("Track Selected") { Task { await trackSelected(session) } }
                    .buttonStyle(.glassProminent)
                    .disabled(selectedOrganizations.isEmpty)
            }
        }
        .padding(20)
        .frame(maxWidth: 440)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
    }
}

@MainActor
@Observable
final class BrowserController {
    weak var webView: WKWebView?
}

private struct PasteSessionSheet: View {
    let target: WebSignInView.Target
    let onSubmit: (String) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var value = ""
    @State private var error: String?
    @State private var checking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Paste a \(target.domain) session").font(.headline)
            Text("""
            1. Open \(target.domain) in your browser, signed in to the account to add.
            2. Open Developer Tools (⌥⌘I) → Application (Chrome) or Storage (Safari) → Cookies → https://\(target.domain).
            3. Copy the value of **\(target.sessionCookie)** and paste it below. You can also paste a whole Cookie header.
            """)
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)

            TextField(target.sessionCookie, text: $value, axis: .vertical)
                .lineLimit(3...6)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())

            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(checking ? "Checking…" : "Add Account") {
                    Task {
                        checking = true
                        error = await onSubmit(cookieHeader)
                        checking = false
                        if error == nil { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || checking)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    /// A bare value becomes `name=value`; anything with `=` is taken as a Cookie header already.
    private var cookieHeader: String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"^[Cc]ookie:\s*"#, with: "", options: .regularExpression)
        return trimmed.contains("=") ? trimmed : "\(target.sessionCookie)=\(trimmed)"
    }
}

private struct SignInWebView: NSViewRepresentable {
    let target: WebSignInView.Target
    let controller: BrowserController
    let onSignedIn: @MainActor (_ name: String, _ cookies: String, _ userAgent: String?) async -> String?

    func makeCoordinator() -> Coordinator { Coordinator(target: target, onSignedIn: onSignedIn) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // A fresh, non-persistent store per sign-in keeps accounts from sharing cookies.
        configuration.websiteDataStore = .nonPersistent()
        // Keep WebKit's real UA but add Safari's suffix, as Safari itself does. Google refuses to sign
        // in from web views without it, and a fully spoofed UA can fail Cloudflare's bot check.
        configuration.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15"
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.load(URLRequest(url: target.loginURL))
        controller.webView = webView
        context.coordinator.start(webView)
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let target: WebSignInView.Target
        let onSignedIn: @MainActor (String, String, String?) async -> String?
        private weak var webView: WKWebView?
        private var timer: Timer?
        private var busy = false
        private var done = false

        init(target: WebSignInView.Target, onSignedIn: @escaping @MainActor (String, String, String?) async -> String?) {
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
            popups.forEach { $0.close() }
            popups.removeAll()
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { await probe() }
        }

        private var popups: [NSWindow] = []

        /// "Continue with Google/Apple" opens a pop-up that reports back to the page through
        /// `window.opener`, so it needs a real child web view in its own window.
        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            let popup = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 640), configuration: configuration)
            popup.uiDelegate = self
            let window = NSWindow(
                contentRect: popup.frame,
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Sign In"
            window.contentView = popup
            window.isReleasedWhenClosed = false
            window.center()
            window.makeKeyAndOrderFront(nil)
            popups.append(window)
            return popup
        }

        /// The provider closes its pop-up (`window.close()`) once sign-in finishes.
        func webViewDidClose(_ webView: WKWebView) {
            guard let window = popups.first(where: { $0.contentView === webView }) else { return }
            window.close()
            popups.removeAll { $0 === window }
        }

        private func probe() async {
            guard !done, !busy, let webView,
                  let host = webView.url?.host(), host == target.domain || host.hasSuffix(".\(target.domain)")
            else { return }
            busy = true
            defer { busy = false }

            guard let result = try? await webView.callAsyncJavaScript(target.probeScript, contentWorld: .page),
                  let name = result as? String
            else { return }

            let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
                .filter { $0.domain == target.domain || $0.domain.hasSuffix(".\(target.domain)") }
            guard !cookies.isEmpty else { return }
            let userAgent = try? await webView.evaluateJavaScript("navigator.userAgent") as? String

            done = true
            stop()
            // Store only the cookies the login needs; fall back to all of them if that isn't enough.
            let essential = cookies.filter(target.isEssential)
            if !essential.isEmpty, await onSignedIn(name, CookieHeader.make(from: essential), userAgent) == nil { return }
            if await onSignedIn(name, CookieHeader.make(from: cookies), userAgent) != nil {
                // The session didn't work from outside the browser. Try again after the next page
                // load (not on a timer, to avoid hammering the provider), or the user can paste instead.
                done = false
            }
        }
    }
}
