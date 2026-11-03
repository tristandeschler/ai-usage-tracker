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

/// Usage through one API key. Spend per key comes from Anthropic's analytics API; OpenAI
/// doesn't report it.
public struct APIKeyUsage: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var today: Int
    public var lastSevenDays: Int
    public var spendLastSevenDays: Double?

    public init(id: String, name: String, today: Int, lastSevenDays: Int, spendLastSevenDays: Double? = nil) {
        self.id = id
        self.name = name
        self.today = today
        self.lastSevenDays = lastSevenDays
        self.spendLastSevenDays = spendLastSevenDays
    }
}

/// Organization-wide API usage from the Anthropic and OpenAI admin APIs. These need an
/// admin key; ordinary API keys can't read usage.
public enum AdminAPIUsage {
    static let days = 7

    /// Token counts per API key id ("" for usage without a key, like the Anthropic Console),
    /// each with one entry per UTC day, oldest first.
    typealias PerKey = [String: [TokenCounts]]

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

    static func totals(_ perKey: PerKey) -> TokenTotals {
        var perDay = Array(repeating: TokenCounts(), count: days)
        for counts in perKey.values {
            for (day, value) in counts.enumerated() { perDay[day] = perDay[day] + value }
        }
        return TokenTotals(
            today: perDay.last ?? TokenCounts(),
            lastSevenDays: perDay.reduce(TokenCounts(), +),
            daily: perDay.map(\.total)
        )
    }

    /// Per-key totals, busiest first, named from `names` where the provider knows them.
    /// `spend` (dollars per key over the week) is optional; keys that only show up there are kept.
    static func keys(_ perKey: PerKey, spend: [String: Double]? = nil, names: [String: String], unattributed: String) -> [APIKeyUsage] {
        Set(perKey.keys).union(spend?.keys ?? [:].keys).map { id in
            let counts = perKey[id] ?? []
            return APIKeyUsage(
                id: id,
                name: id.isEmpty ? unattributed : names[id] ?? "Key …\(id.suffix(6))",
                today: counts.last?.total ?? 0,
                lastSevenDays: counts.reduce(0) { $0 + $1.total },
                spendLastSevenDays: spend.map { $0[id] ?? 0 }
            )
        }
        .filter { $0.lastSevenDays > 0 || ($0.spendLastSevenDays ?? 0) > 0 }
        .sorted { ($0.spendLastSevenDays ?? 0, $0.lastSevenDays) > ($1.spendLastSevenDays ?? 0, $1.lastSevenDays) }
    }

    /// `GET /v1/organizations/analytics/cost?group_by[]=api_key_id` (beta). Rows are flat, one per
    /// day and key; `cost.amount` is a decimal string in cents. Returns dollars per key for the week.
    static func parseAnthropicKeySpend(_ pages: [Data], start: Date) throws -> [String: Double] {
        var spend: [String: Double] = [:]
        for row in try pages.flatMap(buckets) {
            guard let date = DateParsing.iso8601(row["starting_at"] as? String), slot(date, start: start) != nil else { continue }
            let key = ((row["group"] as? [String: Any])?["api_key_id"] as? String) ?? ""
            let cents = ClaudeUsageParser.number((row["cost"] as? [String: Any])?["amount"]) ?? 0
            spend[key, default: 0] += cents / 100
        }
        return spend
    }

    private static func add(_ counts: TokenCounts, key: String?, slot: Int, to perKey: inout PerKey) {
        var row = perKey[key ?? ""] ?? Array(repeating: TokenCounts(), count: days)
        row[slot] = row[slot] + counts
        perKey[key ?? ""] = row
    }

    // MARK: Anthropic

    /// `GET /v1/organizations/usage_report/messages?group_by[]=api_key_id`, daily buckets.
    static func parseAnthropicTokens(_ pages: [Data], start: Date) throws -> PerKey {
        var perKey: PerKey = [:]
        for bucket in try pages.flatMap(buckets) {
            guard let date = DateParsing.iso8601(bucket["starting_at"] as? String), let slot = slot(date, start: start) else { continue }
            for result in (bucket["results"] as? [[String: Any]]) ?? [] {
                func int(_ value: Any?) -> Int { ClaudeUsageParser.number(value).map(Int.init) ?? 0 }
                let creation = result["cache_creation"] as? [String: Any] ?? [:]
                let counts = TokenCounts(
                    input: int(result["uncached_input_tokens"]),
                    output: int(result["output_tokens"]),
                    cacheRead: int(result["cache_read_input_tokens"]),
                    cacheWrite: int(creation["ephemeral_5m_input_tokens"]) + int(creation["ephemeral_1h_input_tokens"])
                )
                add(counts, key: result["api_key_id"] as? String, slot: slot, to: &perKey)
            }
        }
        return perKey
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

    /// `GET /v1/organizations/api_keys`: id → name.
    static func parseAnthropicKeyNames(_ page: Data) -> (names: [String: String], nextCursor: String?) {
        guard let json = try? JSONSerialization.jsonObject(with: page) as? [String: Any] else { return ([:], nil) }
        var names: [String: String] = [:]
        for key in (json["data"] as? [[String: Any]]) ?? [] {
            if let id = key["id"] as? String { names[id] = (key["name"] as? String) ?? id }
        }
        let next = json["has_more"] as? Bool == true ? json["last_id"] as? String : nil
        return (names, next)
    }

    // MARK: OpenAI

    /// `GET /v1/organization/usage/completions?group_by=api_key_id`. OpenAI counts cached
    /// tokens inside `input_tokens`.
    static func parseOpenAITokens(_ pages: [Data], start: Date) throws -> PerKey {
        var perKey: PerKey = [:]
        for bucket in try pages.flatMap(buckets) {
            guard let epoch = ClaudeUsageParser.number(bucket["start_time"]),
                  let slot = slot(Date(timeIntervalSince1970: epoch), start: start) else { continue }
            for result in (bucket["results"] as? [[String: Any]]) ?? [] {
                func int(_ name: String) -> Int { ClaudeUsageParser.number(result[name]).map(Int.init) ?? 0 }
                let cached = int("input_cached_tokens")
                let counts = TokenCounts(
                    input: max(0, int("input_tokens") - cached),
                    output: int("output_tokens"),
                    cacheRead: cached
                )
                add(counts, key: result["api_key_id"] as? String, slot: slot, to: &perKey)
            }
        }
        return perKey
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

    /// OpenAI list endpoints (`/organization/projects`, `/projects/{id}/api_keys`): ids, names, cursor.
    static func parseOpenAIList(_ page: Data) -> (items: [(id: String, name: String)], nextCursor: String?) {
        guard let json = try? JSONSerialization.jsonObject(with: page) as? [String: Any] else { return ([], nil) }
        let items = ((json["data"] as? [[String: Any]]) ?? []).compactMap { item -> (String, String)? in
            guard let id = item["id"] as? String else { return nil }
            return (id, (item["name"] as? String) ?? id)
        }
        let next = json["has_more"] as? Bool == true ? json["last_id"] as? String : nil
        return (items, next)
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

/// Key names change rarely and OpenAI needs a request per project to list them, so they're
/// cached for an hour per admin key.
actor APIKeyNameCache {
    static let shared = APIKeyNameCache()
    private var entries: [String: (names: [String: String], fetched: Date)] = [:]

    func names(for account: String, load: () async -> [String: String]?) async -> [String: String] {
        if let entry = entries[account], entry.fetched > Date().addingTimeInterval(-3_600) { return entry.names }
        guard let names = await load() else { return entries[account]?.names ?? [:] }
        entries[account] = (names, Date())
        return names
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
            let tokens = try await adminPages(
                "https://api.anthropic.com/v1/organizations/usage_report/messages",
                query + [URLQueryItem(name: "group_by[]", value: "api_key_id")], auth, provider
            )
            let costs = try await adminPages("https://api.anthropic.com/v1/organizations/cost_report", query, auth, provider)
            let perKey = try AdminAPIUsage.parseAnthropicTokens(tokens, start: start)
            let names = await APIKeyNameCache.shared.names(for: secretKey) { await anthropicKeyNames(auth) }
            // Spend per key is a beta API; if it fails, keys just show tokens.
            let keySpendPages = try? await adminPages(
                "https://api.anthropic.com/v1/organizations/analytics/cost",
                [
                    URLQueryItem(name: "starting_at", value: iso.string(from: start)),
                    URLQueryItem(name: "ending_at", value: iso.string(from: end)),
                    URLQueryItem(name: "time_bucket_width", value: "1d"),
                    URLQueryItem(name: "group_by[]", value: "api_key_id"),
                    URLQueryItem(name: "order_by", value: "time"),
                    URLQueryItem(name: "limit", value: "1000"),
                ],
                auth + [("anthropic-beta", "analytics-usage-cost-2026-08-24")], provider
            )
            let keySpend = keySpendPages.flatMap { try? AdminAPIUsage.parseAnthropicKeySpend($0, start: start) }
            usage.tokens = AdminAPIUsage.totals(perKey)
            usage.apiKeys = AdminAPIUsage.keys(perKey, spend: keySpend, names: names, unattributed: "Console & Workbench")
            usage.spend = SpendTotals(daily: try AdminAPIUsage.parseAnthropicSpend(costs, start: start))

        case .openai:
            let query = [
                URLQueryItem(name: "start_time", value: String(Int(start.timeIntervalSince1970))),
                URLQueryItem(name: "end_time", value: String(Int(end.timeIntervalSince1970))),
                URLQueryItem(name: "bucket_width", value: "1d"),
                URLQueryItem(name: "limit", value: String(AdminAPIUsage.days)),
            ]
            let auth = [("Authorization", "Bearer \(key)")]
            let tokens = try await adminPages(
                "https://api.openai.com/v1/organization/usage/completions",
                query + [URLQueryItem(name: "group_by", value: "api_key_id")], auth, provider
            )
            let costs = try await adminPages("https://api.openai.com/v1/organization/costs", query, auth, provider)
            let perKey = try AdminAPIUsage.parseOpenAITokens(tokens, start: start)
            let names = await APIKeyNameCache.shared.names(for: secretKey) { await openAIKeyNames(auth) }
            usage.tokens = AdminAPIUsage.totals(perKey)
            usage.apiKeys = AdminAPIUsage.keys(perKey, names: names, unattributed: "No key")
            usage.spend = SpendTotals(daily: try AdminAPIUsage.parseOpenAISpend(costs, start: start))
        }
        usage.plan = "API"
        return usage
    }

    /// Key names are a nicety: any failure here just leaves keys labelled by id.
    private func anthropicKeyNames(_ auth: [(String, String)]) async -> [String: String]? {
        var names: [String: String] = [:]
        var cursor: String?
        for _ in 0..<10 {
            var query = [URLQueryItem(name: "limit", value: "1000")]
            if let cursor { query.append(URLQueryItem(name: "after_id", value: cursor)) }
            guard let page = try? await adminGet("https://api.anthropic.com/v1/organizations/api_keys", query, auth) else { return nil }
            let parsed = AdminAPIUsage.parseAnthropicKeyNames(page)
            names.merge(parsed.names) { $1 }
            guard let next = parsed.nextCursor else { break }
            cursor = next
        }
        return names
    }

    /// OpenAI only lists keys per project, so this walks every project.
    private func openAIKeyNames(_ auth: [(String, String)]) async -> [String: String]? {
        func list(_ url: String) async -> [(id: String, name: String)]? {
            var items: [(id: String, name: String)] = []
            var cursor: String?
            for _ in 0..<10 {
                var query = [URLQueryItem(name: "limit", value: "100")]
                if let cursor { query.append(URLQueryItem(name: "after", value: cursor)) }
                guard let page = try? await adminGet(url, query, auth) else { return nil }
                let parsed = AdminAPIUsage.parseOpenAIList(page)
                items += parsed.items
                guard let next = parsed.nextCursor else { break }
                cursor = next
            }
            return items
        }
        guard let projects = await list("https://api.openai.com/v1/organization/projects") else { return nil }
        var names: [String: String] = [:]
        for project in projects {
            for key in await list("https://api.openai.com/v1/organization/projects/\(project.id)/api_keys") ?? [] {
                names[key.id] = projects.count > 1 ? "\(key.name) · \(project.name)" : key.name
            }
        }
        return names
    }

    private func adminGet(_ url: String, _ query: [URLQueryItem], _ headers: [(String, String)]) async throws -> Data {
        var components = URLComponents(string: url)!
        components.queryItems = query
        var request = URLRequest(url: components.url!)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await http.send(request)
        guard (200..<300).contains(response.statusCode) else { throw UsageError.http(status: response.statusCode, body: nil) }
        return data
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
