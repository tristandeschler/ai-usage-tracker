import Foundation

/// A claude.ai organization. One login can belong to several (e.g. a personal Max plan and a
/// Team plan), and each has its own usage limits.
public struct ClaudeOrganization: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var capabilities: [String]
    /// e.g. `default_claude_max_20x`, when claude.ai includes it.
    public var rateLimitTier: String?

    public init(id: String, name: String, capabilities: [String], rateLimitTier: String? = nil) {
        self.id = id
        self.name = name
        self.capabilities = capabilities
        self.rateLimitTier = rateLimitTier
    }

    init?(json: [String: Any]) {
        guard let id = json["uuid"] as? String else { return nil }
        self.init(
            id: id,
            name: (json["name"] as? String) ?? "Claude",
            capabilities: (json["capabilities"] as? [String]) ?? [],
            rateLimitTier: json["rate_limit_tier"] as? String
        )
    }

    /// The name without claude.ai's default "'s Organization" suffix.
    public var displayName: String {
        name.replacingOccurrences(of: #"'s Organization$"#, with: "", options: .regularExpression)
    }

    public var plan: String? {
        let caps = Set(capabilities)
        if caps.contains("claude_max") {
            return ClaudeUsageParser.planName(subscriptionType: "max", rateLimitTier: rateLimitTier)
        }
        if caps.contains("claude_pro") { return "Pro" }
        if caps.contains(where: { $0.contains("enterprise") }) { return "Enterprise" }
        if caps.contains("raven") || caps.contains(where: { $0.contains("team") }) { return "Team" }
        return nil
    }

    /// Whether this organization has claude.ai chat usage at all (API-only orgs don't).
    public var hasChat: Bool {
        capabilities.contains("chat") || plan != nil
    }

    /// Parses `/api/organizations`, dropping API-only orgs unless that would leave nothing.
    static func parseList(_ data: Data) throws -> [ClaudeOrganization] {
        guard let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw UsageError.invalidResponse("Claude organizations were not a list")
        }
        let orgs = list.compactMap(ClaudeOrganization.init(json:))
        let chat = orgs.filter(\.hasChat)
        return chat.isEmpty ? orgs : chat
    }

    /// Paid personal plans first, then anything with chat.
    static func preferred(_ orgs: [ClaudeOrganization]) -> ClaudeOrganization? {
        orgs.first { $0.capabilities.contains("claude_max") }
            ?? orgs.first { $0.capabilities.contains("claude_pro") }
            ?? orgs.first(where: \.hasChat)
            ?? orgs.first
    }
}
