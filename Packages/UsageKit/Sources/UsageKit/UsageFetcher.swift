import Foundation

public struct UsageFetcher: Sendable {
    /// How the app identifies itself when it isn't replaying a browser session.
    public static let appUserAgent = "TokenTracker/0.2 (+https://github.com/tristandeschler/ai-usage-tracker)"

    /// Used for pasted web sessions. Sign-ins through the app store the web view's own UA instead
    /// (see `userAgentKey`), since Cloudflare ties its clearance cookie to the UA that earned it.
    public static let browserUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    public var http: any HTTPClient
    public var secrets: any SecretStore

    public init(http: any HTTPClient, secrets: any SecretStore) {
        self.http = http
        self.secrets = secrets
    }

    /// Fetches an account and folds failures into the snapshot so the UI can show them inline.
    public func snapshot(for account: AccountConfig) async -> AccountSnapshot {
        do {
            return AccountSnapshot(account: account, usage: try await usage(for: account))
        } catch {
            return AccountSnapshot(
                id: account.id, accountName: account.name, provider: account.provider,
                error: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            )
        }
    }

    public func usage(for account: AccountConfig) async throws -> ProviderUsage {
        switch account.source {
        case let .claudeWeb(organizationID): try await claudeWebUsage(secretKey: account.id.uuidString, organizationID: organizationID)
        case .chatGPTWeb: try await chatGPTWebUsage(secretKey: account.id.uuidString)
        case .anthropicAdmin: try await adminUsage(provider: .anthropic, secretKey: account.id.uuidString)
        case .openAIAdmin: try await adminUsage(provider: .openai, secretKey: account.id.uuidString)
        }
    }

    /// Secret-store key holding the User-Agent that goes with a web session's cookies.
    public static func userAgentKey(_ accountKey: String) -> String { accountKey + ".userAgent" }

    private func userAgent(for secretKey: String) -> String {
        ((try? secrets.read(Self.userAgentKey(secretKey))) ?? nil) ?? Self.browserUserAgent
    }

    // MARK: Claude

    /// Lists the organizations a claude.ai session can see, so the user can pick which to track.
    public func claudeOrganizations(cookies: String, userAgent: String?) async throws -> [ClaudeOrganization] {
        var request = URLRequest(url: URL(string: "https://claude.ai/api/organizations")!)
        request.setValue(cookies, forHTTPHeaderField: "Cookie")
        request.setValue(userAgent ?? Self.browserUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await http.send(request)
        try check(response, data: data, reauthHint: "Sign in to claude.ai again.")
        return try ClaudeOrganization.parseList(data)
    }

    private func claudeWebUsage(secretKey: String, organizationID: String?) async throws -> ProviderUsage {
        let hint = "Sign in to claude.ai again from Settings → Accounts."
        guard var cookies = try secrets.read(secretKey), !cookies.isEmpty else { throw UsageError.notSignedIn(hint) }
        let userAgent = userAgent(for: secretKey)

        func get(_ url: String) async throws -> Data {
            var request = URLRequest(url: URL(string: url)!)
            request.setValue(cookies, forHTTPHeaderField: "Cookie")
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await http.send(request)
            if let merged = CookieHeader.merging(cookies, response: response) {
                cookies = merged
                try? secrets.write(merged, for: secretKey)
            }
            try check(response, data: data, reauthHint: hint)
            return data
        }

        let orgs = try ClaudeOrganization.parseList(try await get("https://claude.ai/api/organizations"))
        let org: ClaudeOrganization
        if let organizationID {
            guard let match = orgs.first(where: { $0.id == organizationID }) else {
                throw UsageError.notSignedIn("This login can't see that Claude account anymore.")
            }
            org = match
        } else {
            guard let preferred = ClaudeOrganization.preferred(orgs) else {
                throw UsageError.invalidResponse("no Claude organization on this account")
            }
            org = preferred
        }

        var usage = try ClaudeUsageParser.parse(try await get("https://claude.ai/api/organizations/\(org.id)/usage"))
        usage.plan = org.plan
        usage.identity = org.displayName
        return usage
    }

    // MARK: OpenAI

    private func chatGPTWebUsage(secretKey: String) async throws -> ProviderUsage {
        let hint = "Sign in to chatgpt.com again from Settings → Accounts."
        guard let cookies = try secrets.read(secretKey), !cookies.isEmpty else { throw UsageError.notSignedIn(hint) }
        let userAgent = userAgent(for: secretKey)

        var request = URLRequest(url: URL(string: "https://chatgpt.com/api/auth/session")!)
        request.setValue(cookies, forHTTPHeaderField: "Cookie")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await http.send(request)
        var current = cookies
        if let merged = CookieHeader.merging(cookies, response: response) {
            current = merged
            try? secrets.write(merged, for: secretKey)
        }
        try check(response, data: data, reauthHint: hint)

        guard let session = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = session["accessToken"] as? String, !token.isEmpty
        else { throw UsageError.expired(hint) }
        let email = (session["user"] as? [String: Any])?["email"] as? String
        let accountID = (session["account"] as? [String: Any])?["id"] as? String

        return try await whamUsage(bearer: token, accountID: accountID, cookies: current, userAgent: userAgent, fallbackEmail: email)
    }

    private func whamUsage(
        bearer: String, accountID: String?, cookies: String, userAgent: String, fallbackEmail: String?
    ) async throws -> ProviderUsage {
        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let accountID { request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id") }
        request.setValue(cookies, forHTTPHeaderField: "Cookie")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await http.send(request)
        try check(response, data: data, reauthHint: "Sign in again.")
        var usage = try CodexUsageParser.parse(data)
        if usage.identity == nil { usage.identity = fallbackEmail }
        return usage
    }

    // MARK: Shared

    func check(_ response: HTTPURLResponse, data: Data, reauthHint: String) throws {
        switch response.statusCode {
        case 200 ..< 300:
            return
        case 401:
            throw UsageError.unauthorized(reauthHint)
        case 403:
            let body = String(decoding: data.prefix(2048), as: UTF8.self)
            if body.contains("Just a moment") || body.contains("cf-chl") || body.contains("challenge-platform") {
                throw UsageError.blockedByCloudflare
            }
            throw UsageError.unauthorized(reauthHint)
        case 429:
            let retryAfter = response.value(forHTTPHeaderField: "Retry-After")
                .flatMap(TimeInterval.init)
                .map { Date().addingTimeInterval($0) }
            throw UsageError.rateLimited(retryAfter: retryAfter)
        default:
            let body = String(data: data.prefix(300), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw UsageError.http(status: response.statusCode, body: body)
        }
    }
}
