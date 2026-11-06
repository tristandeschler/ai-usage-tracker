import Foundation

public enum ProviderKind: String, Codable, Sendable, CaseIterable {
    case anthropic
    case openai

    public var displayName: String {
        switch self {
        case .anthropic: "Claude"
        case .openai: "ChatGPT"
        }
    }
}

/// Where an account's credentials come from.
public enum CredentialSource: Codable, Hashable, Sendable {
    /// claude.ai browser cookies, stored in our own Keychain under the account id. One login can
    /// reach several organizations; nil tracks the paid personal one.
    case claudeWeb(organizationID: String?)
    /// chatgpt.com browser cookies, stored in our own Keychain under the account id.
    case chatGPTWeb
    /// An Anthropic Admin API key (stored in our Keychain) for organization-wide API usage and spend.
    case anthropicAdmin
    /// An OpenAI Admin API key (stored in our Keychain) for organization-wide API usage and spend.
    case openAIAdmin

    public var provider: ProviderKind {
        switch self {
        case .claudeWeb, .anthropicAdmin: .anthropic
        case .chatGPTWeb, .openAIAdmin: .openai
        }
    }

    public var displayName: String {
        switch self {
        case .claudeWeb: "claude.ai session"
        case .chatGPTWeb: "chatgpt.com session"
        case .anthropicAdmin: "Anthropic Admin API key"
        case .openAIAdmin: "OpenAI Admin API key"
        }
    }

    /// API usage accounts report spend and tokens instead of plan limits.
    public var isAPI: Bool {
        switch self {
        case .anthropicAdmin, .openAIAdmin: true
        default: false
        }
    }
}

public struct AccountConfig: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var source: CredentialSource
    public var isEnabled: Bool

    public init(id: UUID = UUID(), name: String, source: CredentialSource, isEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.source = source
        self.isEnabled = isEnabled
    }

    public var provider: ProviderKind { source.provider }

    /// Decodes the saved account list, skipping entries this version can't read (such as the Claude
    /// Code and Codex CLI logins it no longer supports) instead of losing the whole list.
    public static func decodeSaved(_ data: Data) -> (accounts: [AccountConfig], skipped: Int) {
        struct Entry: Decodable {
            let account: AccountConfig?
            init(from decoder: Decoder) { account = try? AccountConfig(from: decoder) }
        }
        let entries = (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
        let accounts = entries.compactMap(\.account)
        return (accounts, entries.count - accounts.count)
    }

    /// The tracked account a fresh sign-in belongs to, if any, so signing in again renews that
    /// account rather than adding a duplicate. Snapshots keep their identity and plan after a
    /// login expires. The plan tells apart two ChatGPT workspaces on one email.
    public static func existing(
        in accounts: [AccountConfig], source: CredentialSource, usage: ProviderUsage, snapshots: [UUID: AccountSnapshot]
    ) -> AccountConfig? {
        if case .claudeWeb(.some) = source, let exact = accounts.first(where: { $0.source == source }) { return exact }
        guard let identity = usage.identity else { return nil }
        return accounts.first { account in
            guard account.source == .chatGPTWeb || account.source == .claudeWeb(organizationID: nil),
                  account.provider == source.provider,
                  let snapshot = snapshots[account.id]
            else { return false }
            return snapshot.identity == identity && snapshot.plan == usage.plan
        }
    }
}

public struct UsageWindow: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case session
        case weekly
        case weeklyModel
        case other
    }

    /// Stable key used for alert state, e.g. `session`, `weekly`, `weekly:Opus`.
    public var id: String
    public var label: String
    public var kind: Kind
    /// 0–100.
    public var usedPercent: Double
    public var resetsAt: Date?

    public init(id: String, label: String, kind: Kind, usedPercent: Double, resetsAt: Date?) {
        self.id = id
        self.label = label
        self.kind = kind
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }

    public var isExhausted: Bool { usedPercent >= 100 }
}

/// Usage as returned by one provider fetch, before it is attached to an account.
public struct ProviderUsage: Hashable, Sendable {
    public var windows: [UsageWindow]
    /// API accounts: organization-wide tokens and spend for the last 7 days.
    public var tokens: TokenTotals?
    public var spend: SpendTotals?
    public var apiKeys: [APIKeyUsage]?
    public var plan: String?
    public var identity: String?
    /// The provider says requests are currently blocked, even if no window shows 100%.
    public var limitReached: Bool

    public init(windows: [UsageWindow], plan: String? = nil, identity: String? = nil, limitReached: Bool = false) {
        self.windows = windows
        self.plan = plan
        self.identity = identity
        self.limitReached = limitReached
    }
}

public struct AccountSnapshot: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var accountName: String
    public var provider: ProviderKind
    public var plan: String?
    public var identity: String?
    public var windows: [UsageWindow]
    public var limitReached: Bool
    public var fetchedAt: Date
    public var error: String?
    /// API accounts: organization-wide tokens and spend for the last 7 days.
    public var tokens: TokenTotals?
    public var spend: SpendTotals?
    /// API accounts: tokens per API key, busiest first.
    public var apiKeys: [APIKeyUsage]?

    public init(
        id: UUID,
        accountName: String,
        provider: ProviderKind,
        plan: String? = nil,
        identity: String? = nil,
        windows: [UsageWindow] = [],
        limitReached: Bool = false,
        fetchedAt: Date = Date(),
        error: String? = nil
    ) {
        self.id = id
        self.accountName = accountName
        self.provider = provider
        self.plan = plan
        self.identity = identity
        self.windows = windows
        self.limitReached = limitReached
        self.fetchedAt = fetchedAt
        self.error = error
    }

    public init(account: AccountConfig, usage: ProviderUsage, fetchedAt: Date = Date()) {
        self.init(
            id: account.id,
            accountName: account.name,
            provider: account.provider,
            plan: usage.plan,
            identity: usage.identity,
            windows: usage.windows,
            limitReached: usage.limitReached,
            fetchedAt: fetchedAt
        )
        tokens = usage.tokens
        spend = usage.spend
        apiKeys = usage.apiKeys
    }

    /// Highest utilization across all windows.
    public var peakPercent: Double? { windows.map(\.usedPercent).max() }

    public var isLimited: Bool { limitReached || windows.contains(where: \.isExhausted) }

    /// Whether any window's usage grew since `previous`, meaning the account is being used right now.
    /// A window that newly appears with usage (Claude's session window after a reset) counts too.
    public func isRising(from previous: AccountSnapshot?) -> Bool {
        guard let previous, error == nil else { return false }
        let before = Dictionary(previous.windows.map { ($0.id, $0.usedPercent) }, uniquingKeysWith: max)
        return windows.contains { window in
            guard let old = before[window.id] else { return window.usedPercent > 0 }
            // A drop means the window reset; only growth within the same window counts.
            return window.usedPercent > old
        }
    }

    /// When the last exhausted window resets, i.e. when this account becomes usable again.
    public var unblockedAt: Date? {
        windows.filter(\.isExhausted).compactMap(\.resetsAt).max()
    }
}
