import AppKit
import SwiftUI
import UsageKit

struct SettingsView: View {
    var body: some View {
        TabView {
            AccountsSettings()
                .tabItem { Label("Accounts", systemImage: "person.2") }
            AlertsSettings()
                .tabItem { Label("Alerts", systemImage: "bell.badge") }
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 560, height: 420)
    }
}

// MARK: Accounts

private struct AccountsSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var selection: UUID?
    @State private var renaming: AccountConfig?
    @State private var addingAdminKey: CredentialSource?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            List(selection: $selection) {
                ForEach(model.accounts) { account in
                    AccountRow(account: account) { renaming = account }
                        .tag(account.id)
                }
                .onMove { model.move(from: $0, to: $1) }
            }
            // List-level menu and double-click; a per-row tap gesture would swallow drag-to-reorder.
            .contextMenu(forSelectionType: UUID.self) { ids in
                if let account = model.accounts.first(where: { ids.contains($0.id) }) {
                    Button("Rename…") { renaming = account }
                    Button("Move Up") { model.move(account, by: -1) }
                        .disabled(account.id == model.accounts.first?.id)
                    Button("Move Down") { model.move(account, by: 1) }
                        .disabled(account.id == model.accounts.last?.id)
                    Divider()
                    Button("Remove", role: .destructive) { model.remove(account) }
                }
            } primaryAction: { ids in
                renaming = model.accounts.first { ids.contains($0.id) }
            }
            .overlay {
                if model.accounts.isEmpty {
                    ContentUnavailableView("No Accounts", systemImage: "person.crop.circle.badge.plus",
                                           description: Text("Add a Claude or ChatGPT account below."))
                }
            }

            HStack(spacing: 8) {
                Menu {
                    Section("Plans") {
                        Button("Sign in to claude.ai…") { signIn(.claude) }
                        Button("Sign in to chatgpt.com…") { signIn(.chatGPT) }
                    }
                    Section("API usage") {
                        Button("Anthropic Admin API key…") { addingAdminKey = .anthropicAdmin }
                        Button("OpenAI Admin API key…") { addingAdminKey = .openAIAdmin }
                    }
                } label: {
                    Label("Add Account", systemImage: "plus")
                }
                .menuStyle(.button)
                .buttonStyle(.glass)
                .fixedSize()

                Button("Remove", systemImage: "minus") {
                    if let account = model.accounts.first(where: { $0.id == selection }) { model.remove(account) }
                }
                .buttonStyle(.glass)
                .disabled(selection == nil)

                Spacer()
                Text("Drag to reorder. Double-click to rename.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
        }
        .renameAccountAlert($renaming)
        .sheet(item: $addingAdminKey) { source in
            AdminKeySheet(source: source)
        }
    }

    private func signIn(_ target: WebSignInView.Target) {
        NSApp.activate()
        openWindow(id: WebSignInView.windowID, value: target)
    }
}

private struct AccountRow: View {
    @Environment(AppModel.self) private var model
    let account: AccountConfig
    let onRename: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ProviderBadge(account.provider)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(account.source.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button("Rename", systemImage: "pencil", action: onRename)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Rename")
            Toggle("Enabled", isOn: Binding(
                get: { account.isEnabled },
                set: { var updated = account; updated.isEnabled = $0; model.update(updated) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        .padding(.vertical, 4)
    }
}

extension CredentialSource: @retroactive Identifiable {
    public var id: String { displayName }
}

/// Adds an API usage account from an admin key, checking it first.
private struct AdminKeySheet: View {
    let source: CredentialSource
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var error: String?
    @State private var checking = false

    private var isAnthropic: Bool { source.provider == .anthropic }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ProviderBadge(source.provider)
                Text(isAnthropic ? "Add an Anthropic Admin API key" : "Add an OpenAI Admin API key").font(.headline)
            }
            Text(isAnthropic
                 ? "Shows your organization's API spend and tokens for the last 7 days. Regular API keys can't read usage, so you need an admin key (it starts with sk-ant-admin)."
                 : "Shows your organization's API spend and tokens for the last 7 days. Regular project keys can't read usage, so you need an admin key.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Link(isAnthropic ? "Create one in the Anthropic Console" : "Create one in the OpenAI dashboard",
                 destination: URL(string: isAnthropic
                    ? "https://console.anthropic.com/settings/admin-keys"
                    : "https://platform.openai.com/settings/organization/admin-keys")!)
                .font(.callout)

            SecureField(isAnthropic ? "sk-ant-admin…" : "Admin key", text: $key)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())

            if let error {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            Text("The key stays in your Keychain and is only sent to \(isAnthropic ? "api.anthropic.com" : "api.openai.com").")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(checking ? "Checking…" : "Add") {
                    Task {
                        checking = true
                        error = await model.addAdminAccount(source: source, key: key.trimmingCharacters(in: .whitespacesAndNewlines))
                        checking = false
                        if error == nil { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || checking)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

private struct UpdateStatusRow: View {
    let updater: Updater

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(status)
                if case let .failed(message) = updater.state {
                    Text(message).font(.caption).foregroundStyle(.red)
                }
            }
            Spacer()
            if let release = updater.available {
                Link("What's new", destination: release.pageURL)
                Button("Update to \(release.version)") { Task { await updater.install() } }
                    .buttonStyle(.glassProminent)
                    .disabled(updater.state == .downloading || updater.state == .installing)
            } else {
                Button("Check Now") { Task { await updater.check() } }
                    .disabled(!updater.isSupported || updater.state == .checking)
            }
        }
    }

    private var status: String {
        guard updater.isSupported else { return "Updates need a signed build (this is version \(updater.currentVersion))." }
        switch updater.state {
        case .checking: return "Checking…"
        case .downloading: return "Downloading the update…"
        case .installing: return "Installing. Token Tracker will reopen."
        default:
            if let release = updater.available { return "Version \(release.version) is available (you have \(updater.currentVersion))." }
            return "You're on the latest version (\(updater.currentVersion))."
        }
    }
}

// MARK: Alerts

private struct AlertsSettings: View {
    @Environment(AppModel.self) private var model
    private let options: [Double] = [50, 75, 80, 90, 95, 100]

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                ForEach(options, id: \.self) { threshold in
                    Toggle(threshold >= 100 ? "Limit reached (100%)" : "\(Int(threshold))% used", isOn: Binding(
                        get: { model.settings.thresholds.contains(threshold) },
                        set: { on in
                            var thresholds = Set(model.settings.thresholds)
                            if on { thresholds.insert(threshold) } else { thresholds.remove(threshold) }
                            model.settings.thresholds = thresholds.sorted()
                        }
                    ))
                }
            } header: {
                Text("Notify me at")
            } footer: {
                Text("Each one fires once per limit window, for every account.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Tell me when a maxed-out account is good to go again", isOn: $model.settings.notifyOnReset)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: General

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @State private var launchAtLogin = false

    var body: some View {
        @Bindable var model = model
        Form {
            Picker("Refresh every", selection: $model.settings.refreshMinutes) {
                ForEach([5.0, 10, 15, 30], id: \.self) { minutes in
                    Text("\(Int(minutes)) minutes").tag(minutes)
                }
            }
            Picker("Menu bar shows", selection: $model.settings.menuBarMode) {
                Text("Account in use (usage going up)").tag(MenuBarMode.activeAccount)
                Text("Whichever account is closest to its limit").tag(MenuBarMode.highestUsage)
                Text("Icon only").tag(MenuBarMode.iconOnly)
            }
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { model.launchAtLogin = launchAtLogin }

            Section("Updates") {
                Toggle("Check for updates every day", isOn: $model.settings.checkForUpdates)
                Toggle("Install updates automatically", isOn: $model.settings.installUpdatesAutomatically)
                    .disabled(!model.settings.checkForUpdates)
                UpdateStatusRow(updater: model.updater)
            }

        }
        .formStyle(.grouped)
        .onAppear { launchAtLogin = model.launchAtLogin }
    }
}
