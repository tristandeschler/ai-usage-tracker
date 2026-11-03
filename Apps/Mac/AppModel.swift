import Foundation
import Observation
import Security
import ServiceManagement
import UsageKit

struct AppSettings: Codable, Equatable {
    var refreshMinutes: Double = 5
    var thresholds: [Double] = AlertEvaluator.defaultThresholds
    var notifyOnReset = true
    var showPercentInMenuBar = true
    var iCloudSync = false
}

@MainActor
@Observable
final class AppModel {
    private(set) var accounts: [AccountConfig] = []
    private(set) var snapshots: [UUID: AccountSnapshot] = [:]
    private(set) var isRefreshing = false
    private(set) var lastRefresh: Date?
    private(set) var syncError: String?

    var settings = AppSettings() {
        didSet {
            guard settings != oldValue else { return }
            persist(settings, key: Keys.settings)
            if settings.refreshMinutes != oldValue.refreshMinutes { startPolling() }
            if settings.iCloudSync, !oldValue.iCloudSync { Task { await syncAll() } }
        }
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("Launch at login failed: \(error)")
            }
        }
    }

    let secrets = KeychainSecretStore()
    private let fetcher: UsageFetcher
    private let notifier = Notifier()
    private var alertState = AlertState()
    private var pollTask: Task<Void, Never>?
    private var cloud: CloudSync?
    private var pendingCloudDeletes: [UUID] = []

    private enum Keys {
        static let accounts = "accounts"
        static let snapshots = "snapshots"
        static let settings = "settings"
        static let alertState = "alertState"
    }

    init() {
        fetcher = UsageFetcher(http: URLSession.isolated, secrets: secrets, claudeCode: ClaudeCodeKeychainReader())
        accounts = load(Keys.accounts) ?? []
        settings = load(Keys.settings) ?? AppSettings()
        alertState = load(Keys.alertState) ?? AlertState()
        let cached: [AccountSnapshot] = load(Keys.snapshots) ?? []
        snapshots = Dictionary(uniqueKeysWithValues: cached.map { ($0.id, $0) })

        if accounts.isEmpty { addDetectedLogins() }
        notifier.requestAuthorization()
        startPolling()
    }

    // MARK: Derived state

    var orderedSnapshots: [AccountSnapshot] {
        accounts.filter(\.isEnabled).map {
            snapshots[$0.id] ?? AccountSnapshot(id: $0.id, accountName: $0.name, provider: $0.provider)
        }
    }

    /// Highest usage across all accounts, shown in the menu bar.
    var peakPercent: Double? {
        orderedSnapshots.compactMap(\.peakPercent).max()
    }

    var limitedCount: Int { orderedSnapshots.filter(\.isLimited).count }

    // MARK: Refreshing

    func startPolling() {
        pollTask?.cancel()
        let interval = max(1, settings.refreshMinutes) * 60
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let enabled = accounts.filter(\.isEnabled)
        let fetcher = self.fetcher
        let results = await withTaskGroup(of: AccountSnapshot.self) { group in
            for account in enabled {
                group.addTask { await fetcher.snapshot(for: account) }
            }
            var collected: [AccountSnapshot] = []
            for await snapshot in group { collected.append(snapshot) }
            return collected
        }

        var alerts: [UsageAlert] = []
        for fresh in results {
            var snapshot = fresh
            // Keep the last good numbers visible when a refresh fails, with the error on top.
            if snapshot.error != nil, let previous = snapshots[snapshot.id], !previous.windows.isEmpty {
                snapshot.windows = previous.windows
                snapshot.plan = previous.plan
                snapshot.identity = previous.identity
                snapshot.limitReached = previous.limitReached
                snapshot.fetchedAt = previous.fetchedAt
            }
            snapshots[snapshot.id] = snapshot
            alerts += AlertEvaluator.evaluate(
                fresh, thresholds: settings.thresholds, notifyOnReset: settings.notifyOnReset, state: &alertState
            )
        }

        lastRefresh = Date()
        persist(Array(snapshots.values), key: Keys.snapshots)
        persist(alertState, key: Keys.alertState)

        for alert in alerts { notifier.post(alert) }
        await syncAll(alerts: alerts)
    }

    /// CloudKit raises an exception without the iCloud entitlement, which only paid developer
    /// teams can sign, so sync stays off unless this build has it.
    static let iCloudAvailable: Bool = {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-services" as CFString, nil) != nil
    }()

    private func syncAll(alerts: [UsageAlert] = []) async {
        guard settings.iCloudSync, Self.iCloudAvailable else { return }
        if cloud == nil {
            cloud = CloudSync()
            Task { try? await cloud?.pruneAlerts() }
        }
        guard let cloud else { return }
        do {
            try await cloud.publish(orderedSnapshots, removing: pendingCloudDeletes)
            pendingCloudDeletes = []
            for alert in alerts { try await cloud.publish(alert) }
            syncError = nil
        } catch {
            syncError = error.localizedDescription
        }
    }

    // MARK: Accounts

    func add(_ account: AccountConfig) {
        accounts.append(account)
        saveAccounts()
        Task { await refresh() }
    }

    func update(_ account: AccountConfig) {
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[index] = account
        if var snapshot = snapshots[account.id] {
            snapshot.accountName = account.name
            snapshots[account.id] = snapshot
        }
        saveAccounts()
    }

    func remove(_ account: AccountConfig) {
        accounts.removeAll { $0.id == account.id }
        snapshots[account.id] = nil
        alertState.forget(accountID: account.id)
        if account.source.usesStoredSecret { try? secrets.delete(account.id.uuidString) }
        pendingCloudDeletes.append(account.id)
        saveAccounts()
        persist(alertState, key: Keys.alertState)
        Task { await syncAll() }
    }

    func move(from offsets: IndexSet, to destination: Int) {
        accounts.move(fromOffsets: offsets, toOffset: destination)
        saveAccounts()
    }

    /// Stores cookies from a web sign-in and adds the account, named after the identity it reports.
    func addWebAccount(source: CredentialSource, cookieHeader: String, suggestedName: String?) {
        let account = AccountConfig(name: suggestedName ?? source.provider.displayName, source: source)
        do {
            try secrets.write(cookieHeader, for: account.id.uuidString)
        } catch {
            NSLog("Could not save credentials: \(error)")
            return
        }
        add(account)
    }

    var hasClaudeCodeAccount: Bool { accounts.contains { $0.source == .claudeCode } }

    func hasCodexAccount(path: String) -> Bool {
        accounts.contains { $0.source == .codexCLI(authFilePath: path) }
    }

    private func addDetectedLogins() {
        if (try? ClaudeCodeKeychainReader().load()) != nil {
            accounts.append(AccountConfig(name: "Claude Code", source: .claudeCode))
        }
        let codexPath = CodexAuthFile.defaultPath()
        if let auth = try? CodexAuthFile.load(path: codexPath) {
            accounts.append(AccountConfig(name: auth.email ?? "Codex", source: .codexCLI(authFilePath: codexPath)))
        }
        saveAccounts()
    }

    private func saveAccounts() { persist(accounts, key: Keys.accounts) }

    // MARK: Persistence

    private func persist<T: Encodable>(_ value: T, key: String) {
        UserDefaults.standard.set(try? JSONEncoder().encode(value), forKey: key)
    }

    private func load<T: Decodable>(_ key: String) -> T? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
}
