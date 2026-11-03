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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            List(selection: $selection) {
                ForEach(model.accounts) { account in
                    AccountRow(account: account)
                        .tag(account.id)
                        .contextMenu {
                            Button("Remove", role: .destructive) { model.remove(account) }
                        }
                }
                .onMove { model.move(from: $0, to: $1) }
            }
            .overlay {
                if model.accounts.isEmpty {
                    ContentUnavailableView("No Accounts", systemImage: "person.crop.circle.badge.plus",
                                           description: Text("Add a Claude or ChatGPT account below."))
                }
            }

            HStack(spacing: 8) {
                Menu {
                    Section("Claude") {
                        Button("Use Claude Code login on this Mac") {
                            model.add(AccountConfig(name: "Claude Code", source: .claudeCode))
                        }
                        .disabled(model.hasClaudeCodeAccount)
                        Button("Sign in to claude.ai…") { signIn(.claude) }
                    }
                    Section("ChatGPT / Codex") {
                        Button("Use a Codex CLI login…") { chooseCodexHome() }
                        Button("Sign in to chatgpt.com…") { signIn(.chatGPT) }
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
                Text("Drag to reorder. Names are editable.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
        }
    }

    private func signIn(_ target: WebSignInView.Target) {
        NSApp.activate()
        openWindow(id: WebSignInView.windowID, value: target)
    }

    private func chooseCodexHome() {
        let panel = NSOpenPanel()
        panel.message = "Choose a Codex home folder (the one containing auth.json). Use a separate CODEX_HOME per account."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: (CodexAuthFile.defaultPath() as NSString).deletingLastPathComponent)
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let path = url.appendingPathComponent("auth.json").path
        guard !model.hasCodexAccount(path: path) else { return }
        do {
            let auth = try CodexAuthFile.load(path: path)
            model.add(AccountConfig(name: auth.email ?? url.lastPathComponent, source: .codexCLI(authFilePath: path)))
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "No Codex login in that folder"
            alert.informativeText = "Run `CODEX_HOME=\(url.path) codex login` first, then try again."
            alert.runModal()
        }
    }
}

private struct AccountRow: View {
    @Environment(AppModel.self) private var model
    let account: AccountConfig
    @State private var name = ""

    var body: some View {
        HStack(spacing: 10) {
            ProviderBadge(account.provider)
            VStack(alignment: .leading, spacing: 2) {
                TextField("Name", text: $name)
                    .textFieldStyle(.plain)
                    .font(.body.weight(.medium))
                    .onSubmit(commitName)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Toggle("Enabled", isOn: Binding(
                get: { account.isEnabled },
                set: { var updated = account; updated.isEnabled = $0; model.update(updated) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        .padding(.vertical, 4)
        .onAppear { name = account.name }
        .onChange(of: account.name) { name = account.name }
    }

    private var detail: String {
        switch account.source {
        case let .codexCLI(path):
            "\(account.source.displayName) · \((path as NSString).abbreviatingWithTildeInPath)"
        default:
            account.source.displayName
        }
    }

    private func commitName() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != account.name else { return }
        var updated = account
        updated.name = trimmed
        model.update(updated)
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
                Text("Notify when any session or weekly window reaches")
            } footer: {
                Text("Each threshold fires once per window, for every account.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Notify when a limited account is available again", isOn: $model.settings.notifyOnReset)
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
                ForEach([1.0, 2, 5, 10, 15, 30], id: \.self) { minutes in
                    Text(minutes == 1 ? "minute" : "\(Int(minutes)) minutes").tag(minutes)
                }
            }
            Toggle("Show highest usage % in the menu bar", isOn: $model.settings.showPercentInMenuBar)
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { model.launchAtLogin = launchAtLogin }

            Section {
                Toggle("Sync to iPhone via iCloud", isOn: $model.settings.iCloudSync)
                    .disabled(!AppModel.iCloudAvailable)
                if !AppModel.iCloudAvailable {
                    Text("This build doesn't include iCloud. Build with `make run ICLOUD=YES` using a paid Apple Developer team.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let error = model.syncError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } footer: {
                Text("Only usage numbers are synced to your private iCloud database. Logins and cookies stay on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { launchAtLogin = model.launchAtLogin }
    }
}
