import Foundation
import Observation
import Security
import ServiceManagement
import UsageKit

enum MenuBarMode: String, Codable, CaseIterable {
    /// The account whose usage went up most recently.
    case activeAccount
    case highestUsage
    case iconOnly
}

struct AppSettings: Codable, Equatable {
    var refreshMinutes: Double = 5
    var thresholds: [Double] = AlertEvaluator.defaultThresholds
    var notifyOnReset = true
    var menuBarMode = MenuBarMode.activeAccount
    var iCloudSync = false

    init() {}

    // Tolerate settings saved by older builds: missing keys keep their defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        refreshMinutes = try c.decodeIfPresent(Double.self, forKey: .refreshMinutes) ?? d.refreshMinutes
        thresholds = try c.decodeIfPresent([Double].self, forKey: .thresholds) ?? d.thresholds
        notifyOnReset = try c.decodeIfPresent(Bool.self, forKey: .notifyOnReset) ?? d.notifyOnReset
        menuBarMode = (try? c.decodeIfPresent(MenuBarMode.self, forKey: .menuBarMode)) ?? d.menuBarMode
        iCloudSync = try c.decodeIfPresent(Bool.self, forKey: .iCloudSync) ?? d.iCloudSync
    }
}

@MainActor
@Observable
final class AppModel {
    private(set) var accounts: [AccountConfig] = []
    private(set) var snapshots: [UUID: AccountSnapshot] = [:]
    private(set) var isRefreshing = false
    private(set) var lastRefresh: Date?
    private(set) var syncError: String?
    /// When each account's usage last went up.
    private(set) var lastActivity: [UUID: Date] = [:]

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
        static let lastActivity = "lastActivity"
    }

    init() {
        fetcher = UsageFetcher(http: URLSession.isolated, secrets: secrets, claudeCode: ClaudeCodeKeychainReader())
        accounts = load(Keys.accounts) ?? []
        settings = load(Keys.settings) ?? AppSettings()
        alertState = load(Keys.alertState) ?? AlertState()
        lastActivity = load(Keys.lastActivity) ?? [:]
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

    /// The enabled account whose usage went up most recently.
    var activeAccountID: UUID? {
        accounts.filter(\.isEnabled).compactMap { account in lastActivity[account.id].map { (account.id, $0) } }
            .max { $0.1 < $1.1 }?.0
    }

    private var highestUsageSnapshot: AccountSnapshot? {
        orderedSnapshots.filter { $0.peakPercent != nil }.max { ($0.peakPercent ?? 0) < ($1.peakPercent ?? 0) }
    }

    /// The account whose percentage the menu bar shows.
    var menuBarSnapshot: AccountSnapshot? {
        switch settings.menuBarMode {
        case .activeAccount:
            // Until some account's usage has gone up, fall back to the highest.
            activeAccountID.flatMap { snapshots[$0] } ?? highestUsageSnapshot
        case .highestUsage:
            highestUsageSnapshot
        case .iconOnly:
            nil
        }
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
        let now = Date()
        for fresh in results {
            if fresh.isRising(from: snapshots[fresh.id]) { lastActivity[fresh.id] = now }
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
        persist(lastActivity, key: Keys.lastActivity)

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
        lastActivity[account.id] = nil
        alertState.forget(accountID: account.id)
        if account.source.usesStoredSecret {
            try? secrets.delete(account.id.uuidString)
            try? secrets.delete(UsageFetcher.userAgentKey(account.id.uuidString))
        }
        pendingCloudDeletes.append(account.id)
        saveAccounts()
        persist(alertState, key: Keys.alertState)
        Task { await syncAll() }
    }

    func move(from offsets: IndexSet, to destination: Int) {
        accounts.move(fromOffsets: offsets, toOffset: destination)
        saveAccounts()
    }

    /// Checks a web session against the provider, then stores it and adds the account, named after
    /// the identity the provider reports. Returns an error message instead when the session doesn't work.
    func addWebAccount(source: CredentialSource, cookieHeader: String, userAgent: String?, suggestedName: String?) async -> String? {
        var account = AccountConfig(name: suggestedName ?? source.provider.displayName, source: source)
        let key = account.id.uuidString
        do {
            try secrets.write(cookieHeader, for: key)
            if let userAgent { try secrets.write(userAgent, for: UsageFetcher.userAgentKey(key)) }
            let usage = try await fetcher.usage(for: account)
            if suggestedName == nil, let identity = usage.identity { account.name = identity }
        } catch {
            try? secrets.delete(key)
            try? secrets.delete(UsageFetcher.userAgentKey(key))
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        add(account)
        return nil
    }

    func claudeOrganizations(cookieHeader: String, userAgent: String?) async throws -> [ClaudeOrganization] {
        try await fetcher.claudeOrganizations(cookies: cookieHeader, userAgent: userAgent)
    }

    func isTracking(claudeOrganization id: String) -> Bool {
        accounts.contains { $0.source == .claudeWeb(organizationID: id) }
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
