import Foundation

public struct UsageFetcher: Sendable {
    /// Safari's UA; web-session cookies are minted in a WKWebView using the same string, which
    /// keeps Cloudflare's bot checks consistent between sign-in and polling.
    public static let browserUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    public var http: any HTTPClient
    public var secrets: any SecretStore
    public var claudeCode: (any ClaudeCodeCredentialProvider)?

    public init(http: any HTTPClient, secrets: any SecretStore, claudeCode: (any ClaudeCodeCredentialProvider)?) {
        self.http = http
        self.secrets = secrets
        self.claudeCode = claudeCode
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
        case .claudeCode: try await claudeCodeUsage()
        case .claudeWeb: try await claudeWebUsage(secretKey: account.id.uuidString)
        case let .codexCLI(path): try await codexCLIUsage(path: path)
        case .chatGPTWeb: try await chatGPTWebUsage(secretKey: account.id.uuidString)
        }
    }

    // MARK: Claude

    private func claudeCodeUsage() async throws -> ProviderUsage {
        guard let claudeCode else { throw UsageError.notSignedIn("Claude Code logins are only readable on a Mac.") }
        let credentials = try claudeCode.load()
        if let expiresAt = credentials.expiresAt, expiresAt < Date() {
            throw UsageError.expired("Open Claude Code once to refresh its login.")
        }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("claude-cli/2.1.0 (external, cli)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await http.send(request)
        try check(response, data: data, reauthHint: "Run `claude` and sign in again.")
        var usage = try ClaudeUsageParser.parse(data)
        usage.plan = ClaudeUsageParser.planName(
            subscriptionType: credentials.subscriptionType, rateLimitTier: credentials.rateLimitTier
        )
        return usage
    }

    private func claudeWebUsage(secretKey: String) async throws -> ProviderUsage {
        let hint = "Sign in to claude.ai again from Settings → Accounts."
        guard var cookies = try secrets.read(secretKey), !cookies.isEmpty else { throw UsageError.notSignedIn(hint) }

        func get(_ url: String) async throws -> Data {
            var request = URLRequest(url: URL(string: url)!)
            request.setValue(cookies, forHTTPHeaderField: "Cookie")
            request.setValue(Self.browserUserAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await http.send(request)
            if let merged = CookieHeader.merging(cookies, response: response) {
                cookies = merged
                try? secrets.write(merged, for: secretKey)
            }
            try check(response, data: data, reauthHint: hint)
            return data
        }

        let orgsData = try await get("https://claude.ai/api/organizations")
        guard let orgs = try JSONSerialization.jsonObject(with: orgsData) as? [[String: Any]],
              let org = Self.preferredOrganization(orgs),
              let orgID = org["uuid"] as? String
        else { throw UsageError.invalidResponse("no Claude organization on this account") }

        var usage = try ClaudeUsageParser.parse(try await get("https://claude.ai/api/organizations/\(orgID)/usage"))
        let capabilities = (org["capabilities"] as? [String]) ?? []
        usage.plan = capabilities.contains("claude_max") ? "Max" : capabilities.contains("claude_pro") ? "Pro" : nil
        usage.identity = org["name"] as? String
        return usage
    }

    static func preferredOrganization(_ orgs: [[String: Any]]) -> [String: Any]? {
        func has(_ org: [String: Any], _ capability: String) -> Bool {
            ((org["capabilities"] as? [String]) ?? []).contains(capability)
        }
        return orgs.first { has($0, "claude_max") }
            ?? orgs.first { has($0, "claude_pro") }
            ?? orgs.first { has($0, "chat") }
            ?? orgs.first
    }

    // MARK: OpenAI

    private func codexCLIUsage(path: String) async throws -> ProviderUsage {
        var auth = try CodexAuthFile.load(path: path)
        if auth.isExpired {
            auth = try await auth.refreshed(writingTo: path, http: http)
        }

        do {
            return try await whamUsage(bearer: auth.accessToken, accountID: auth.accountID, cookies: nil, fallbackEmail: auth.email)
        } catch UsageError.unauthorized {
            auth = try await auth.refreshed(writingTo: path, http: http)
            return try await whamUsage(bearer: auth.accessToken, accountID: auth.accountID, cookies: nil, fallbackEmail: auth.email)
        }
    }

    private func chatGPTWebUsage(secretKey: String) async throws -> ProviderUsage {
        let hint = "Sign in to chatgpt.com again from Settings → Accounts."
        guard let cookies = try secrets.read(secretKey), !cookies.isEmpty else { throw UsageError.notSignedIn(hint) }

        var request = URLRequest(url: URL(string: "https://chatgpt.com/api/auth/session")!)
        request.setValue(cookies, forHTTPHeaderField: "Cookie")
        request.setValue(Self.browserUserAgent, forHTTPHeaderField: "User-Agent")
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

        return try await whamUsage(bearer: token, accountID: accountID, cookies: current, fallbackEmail: email)
    }

    private func whamUsage(bearer: String, accountID: String?, cookies: String?, fallbackEmail: String?) async throws -> ProviderUsage {
        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let accountID { request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id") }
        if let cookies {
            request.setValue(cookies, forHTTPHeaderField: "Cookie")
            request.setValue(Self.browserUserAgent, forHTTPHeaderField: "User-Agent")
        } else {
            request.setValue("codex-cli", forHTTPHeaderField: "User-Agent")
        }

        let (data, response) = try await http.send(request)
        try check(response, data: data, reauthHint: "Sign in again.")
        var usage = try CodexUsageParser.parse(data)
        if usage.identity == nil { usage.identity = fallbackEmail }
        return usage
    }

    // MARK: Shared

    private func check(_ response: HTTPURLResponse, data: Data, reauthHint: String) throws {
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
