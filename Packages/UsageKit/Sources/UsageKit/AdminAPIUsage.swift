import Foundation

/// API spend in dollars, per UTC day like the providers report it.
public struct SpendTotals: Codable, Hashable, Sendable {
    public var today: Double
    public var lastSevenDays: Double
    /// Oldest first, ending today.
    public var daily: [Double]

    public init(daily: [Double]) {
        self.daily = daily
        today = daily.last ?? 0
        lastSevenDays = daily.reduce(0, +)
    }
}

/// Organization-wide API usage from the Anthropic and OpenAI admin APIs. These need an
/// admin key; ordinary API keys can't read usage.
public enum AdminAPIUsage {
    static let days = 7

    /// UTC midnight six days ago through now. Both APIs bucket by UTC day.
    static func range(now: Date) -> (start: Date, end: Date) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -(days - 1), to: today) ?? today
        let end = calendar.date(byAdding: .day, value: 1, to: today) ?? now
        return (start, end)
    }

    /// Which of the seven day slots a bucket starting at `date` belongs to.
    static func slot(_ date: Date, start: Date) -> Int? {
        let index = Int((date.timeIntervalSince(start) / 86_400).rounded(.down))
        return (0..<days).contains(index) ? index : nil
    }

    static func totals(_ perDay: [TokenCounts]) -> TokenTotals {
        TokenTotals(
            today: perDay.last ?? TokenCounts(),
            lastSevenDays: perDay.reduce(TokenCounts(), +),
            daily: perDay.map(\.total)
        )
    }

    // MARK: Anthropic

    /// `GET /v1/organizations/usage_report/messages`, daily buckets.
    static func parseAnthropicTokens(_ pages: [Data], start: Date) throws -> [TokenCounts] {
        var perDay = Array(repeating: TokenCounts(), count: days)
        for bucket in try pages.flatMap(buckets) {
            guard let date = DateParsing.iso8601(bucket["starting_at"] as? String), let slot = slot(date, start: start) else { continue }
            for result in (bucket["results"] as? [[String: Any]]) ?? [] {
                func int(_ value: Any?) -> Int { ClaudeUsageParser.number(value).map(Int.init) ?? 0 }
                let creation = result["cache_creation"] as? [String: Any] ?? [:]
                perDay[slot] = perDay[slot] + TokenCounts(
                    input: int(result["uncached_input_tokens"]),
                    output: int(result["output_tokens"]),
                    cacheRead: int(result["cache_read_input_tokens"]),
                    cacheWrite: int(creation["ephemeral_5m_input_tokens"]) + int(creation["ephemeral_1h_input_tokens"])
                )
            }
        }
        return perDay
    }

    /// `GET /v1/organizations/cost_report`. `amount` is a decimal string in cents.
    static func parseAnthropicSpend(_ pages: [Data], start: Date) throws -> [Double] {
        var perDay = Array(repeating: 0.0, count: days)
        for bucket in try pages.flatMap(buckets) {
            guard let date = DateParsing.iso8601(bucket["starting_at"] as? String), let slot = slot(date, start: start) else { continue }
            for result in (bucket["results"] as? [[String: Any]]) ?? [] {
                perDay[slot] += (ClaudeUsageParser.number(result["amount"]) ?? 0) / 100
            }
        }
        return perDay
    }

    // MARK: OpenAI

    /// `GET /v1/organization/usage/completions`. OpenAI counts cached tokens inside `input_tokens`.
    static func parseOpenAITokens(_ pages: [Data], start: Date) throws -> [TokenCounts] {
        var perDay = Array(repeating: TokenCounts(), count: days)
        for bucket in try pages.flatMap(buckets) {
            guard let epoch = ClaudeUsageParser.number(bucket["start_time"]),
                  let slot = slot(Date(timeIntervalSince1970: epoch), start: start) else { continue }
            for result in (bucket["results"] as? [[String: Any]]) ?? [] {
                func int(_ name: String) -> Int { ClaudeUsageParser.number(result[name]).map(Int.init) ?? 0 }
                let cached = int("input_cached_tokens")
                perDay[slot] = perDay[slot] + TokenCounts(
                    input: max(0, int("input_tokens") - cached),
                    output: int("output_tokens"),
                    cacheRead: cached
                )
            }
        }
        return perDay
    }

    /// `GET /v1/organization/costs`. `amount.value` is in dollars.
    static func parseOpenAISpend(_ pages: [Data], start: Date) throws -> [Double] {
        var perDay = Array(repeating: 0.0, count: days)
        for bucket in try pages.flatMap(buckets) {
            guard let epoch = ClaudeUsageParser.number(bucket["start_time"]),
                  let slot = slot(Date(timeIntervalSince1970: epoch), start: start) else { continue }
            for result in (bucket["results"] as? [[String: Any]]) ?? [] {
                perDay[slot] += ClaudeUsageParser.number((result["amount"] as? [String: Any])?["value"]) ?? 0
            }
        }
        return perDay
    }

    private static func buckets(_ page: Data) throws -> [[String: Any]] {
        guard let json = try JSONSerialization.jsonObject(with: page) as? [String: Any],
              let data = json["data"] as? [[String: Any]]
        else { throw UsageError.invalidResponse("usage report had no data") }
        return data
    }

    static func nextPage(_ page: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: page) as? [String: Any],
              json["has_more"] as? Bool == true
        else { return nil }
        return json["next_page"] as? String
    }
}

extension UsageFetcher {
    func adminUsage(provider: ProviderKind, secretKey: String, now: Date = Date()) async throws -> ProviderUsage {
        guard let key = try secrets.read(secretKey), !key.isEmpty else {
            throw UsageError.notSignedIn("Add the admin key again in Settings → Accounts.")
        }
        let (start, end) = AdminAPIUsage.range(now: now)
        var usage = ProviderUsage(windows: [])

        switch provider {
        case .anthropic:
            let iso = ISO8601DateFormatter()
            let query = [
                URLQueryItem(name: "starting_at", value: iso.string(from: start)),
                URLQueryItem(name: "ending_at", value: iso.string(from: end)),
                URLQueryItem(name: "bucket_width", value: "1d"),
                URLQueryItem(name: "limit", value: String(AdminAPIUsage.days)),
            ]
            let auth = [("x-api-key", key), ("anthropic-version", "2023-06-01")]
            let tokens = try await adminPages("https://api.anthropic.com/v1/organizations/usage_report/messages", query, auth, provider)
            let costs = try await adminPages("https://api.anthropic.com/v1/organizations/cost_report", query, auth, provider)
            usage.tokens = AdminAPIUsage.totals(try AdminAPIUsage.parseAnthropicTokens(tokens, start: start))
            usage.spend = SpendTotals(daily: try AdminAPIUsage.parseAnthropicSpend(costs, start: start))

        case .openai:
            let query = [
                URLQueryItem(name: "start_time", value: String(Int(start.timeIntervalSince1970))),
                URLQueryItem(name: "end_time", value: String(Int(end.timeIntervalSince1970))),
                URLQueryItem(name: "bucket_width", value: "1d"),
                URLQueryItem(name: "limit", value: String(AdminAPIUsage.days)),
            ]
            let auth = [("Authorization", "Bearer \(key)")]
            let tokens = try await adminPages("https://api.openai.com/v1/organization/usage/completions", query, auth, provider)
            let costs = try await adminPages("https://api.openai.com/v1/organization/costs", query, auth, provider)
            usage.tokens = AdminAPIUsage.totals(try AdminAPIUsage.parseOpenAITokens(tokens, start: start))
            usage.spend = SpendTotals(daily: try AdminAPIUsage.parseOpenAISpend(costs, start: start))
        }
        usage.plan = "API"
        return usage
    }

    private func adminPages(
        _ url: String, _ query: [URLQueryItem], _ headers: [(String, String)], _ provider: ProviderKind
    ) async throws -> [Data] {
        let hint = provider == .anthropic
            ? "This needs an Anthropic Admin API key (sk-ant-admin…), not a regular one."
            : "This needs an OpenAI Admin API key, not a regular project key."
        var pages: [Data] = []
        var cursor: String?
        repeat {
            var components = URLComponents(string: url)!
            components.queryItems = query + (cursor.map { [URLQueryItem(name: "page", value: $0)] } ?? [])
            var request = URLRequest(url: components.url!)
            for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await http.send(request)
            try check(response, data: data, reauthHint: hint)
            pages.append(data)
            cursor = AdminAPIUsage.nextPage(data)
        } while cursor != nil && pages.count < 10
        return pages
    }
}
