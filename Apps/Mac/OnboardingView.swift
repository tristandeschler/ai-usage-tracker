import SwiftUI
import UsageKit

/// Shown at first launch: sign in once here, so tracking doesn't depend on another tool's login.
struct OnboardingView: View {
    static let windowID = "onboarding"

    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                Text("Welcome to Token Tracker")
                    .font(.title2.weight(.semibold))
                Text("Sign in to the accounts you want to track. Your usage will show up in the menu bar.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.removedLocalLogins {
                Label(
                    "Token Tracker no longer uses Claude Code's and Codex's logins, which expired whenever those tools weren't running. Sign in here to keep tracking those accounts.",
                    systemImage: "info.circle"
                )
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(spacing: 10) {
                row(.claude, title: "Claude", subtitle: "Includes your Claude Code limits")
                row(.chatGPT, title: "ChatGPT", subtitle: "Includes your Codex limits")
            }

            Text("Your logins stay in your Keychain and only go to the service they belong to. API usage and more accounts can be added in Settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                if signedInAccounts.isEmpty {
                    Button("Skip for Now", action: finish)
                } else {
                    Button("Done", action: finish)
                        .buttonStyle(.glassProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 440)
        // Activating is only a request now, and a menu bar app has nothing else on screen to find.
        .onAppear { NSApp.windows.first { $0.identifier?.rawValue == Self.windowID }?.orderFrontRegardless() }
    }

    private var signedInAccounts: [AccountConfig] {
        model.accounts.filter { !$0.source.isAPI }
    }

    private func row(_ target: WebSignInView.Target, title: String, subtitle: String) -> some View {
        let accounts = signedInAccounts.filter { $0.provider == target.source.provider }
        return HStack(spacing: 12) {
            ProviderBadge(target.source.provider, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(accounts) { account in
                    Label(account.name, systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .lineLimit(1)
                }
            }
            Spacer()
            Button(accounts.isEmpty ? "Sign In…" : "Add Another…") {
                NSApp.activate()
                openWindow(id: WebSignInView.windowID, value: target)
            }
            .buttonStyle(.glass)
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: UsageStyle.cardCornerRadius))
    }

    private func finish() {
        model.finishOnboarding()
        dismiss()
    }
}
