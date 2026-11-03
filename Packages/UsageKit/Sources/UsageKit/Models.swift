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
    /// The account currently signed in to Claude Code on this Mac (read from its Keychain item).
    case claudeCode
    /// claude.ai browser cookies, stored in our own Keychain under the account id. One login can
    /// reach several organizations; nil tracks the paid personal one.
    case claudeWeb(organizationID: String?)
    /// A Codex CLI `auth.json` (one per `CODEX_HOME`).
    case codexCLI(authFilePath: String)
    /// chatgpt.com browser cookies, stored in our own Keychain under the account id.
    case chatGPTWeb

    public var provider: ProviderKind {
        switch self {
        case .claudeCode, .claudeWeb: .anthropic
        case .codexCLI, .chatGPTWeb: .openai
        }
    }

    public var displayName: String {
        switch self {
        case .claudeCode: "Claude Code login"
        case .claudeWeb: "claude.ai session"
        case .codexCLI: "Codex CLI login"
        case .chatGPTWeb: "chatgpt.com session"
        }
    }

    /// Whether the secret lives in TokenTracker's own Keychain (vs. a file or another app's item).
    public var usesStoredSecret: Bool {
        switch self {
        case .claudeWeb, .chatGPTWeb: true
        case .claudeCode, .codexCLI: false
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
