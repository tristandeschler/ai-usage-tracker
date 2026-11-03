import Foundation

/// Token counts in the shape both CLIs can report. `input` excludes cached tokens.
public struct TokenCounts: Codable, Hashable, Sendable {
    public var input = 0
    public var output = 0
    public var cacheRead = 0
    public var cacheWrite = 0

    public init(input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
    }

    public var total: Int { input + output + cacheRead + cacheWrite }

    static func + (a: TokenCounts, b: TokenCounts) -> TokenCounts {
        TokenCounts(
            input: a.input + b.input, output: a.output + b.output,
            cacheRead: a.cacheRead + b.cacheRead, cacheWrite: a.cacheWrite + b.cacheWrite
        )
    }
}

public struct TokenTotals: Codable, Hashable, Sendable {
    public var today = TokenCounts()
    /// Today plus the six calendar days before it.
    public var lastSevenDays = TokenCounts()
    /// Total tokens per calendar day, oldest first, ending today. Optional so older caches still decode.
    public var daily: [Int]?

    public init(today: TokenCounts = TokenCounts(), lastSevenDays: TokenCounts = TokenCounts(), daily: [Int]? = nil) {
        self.today = today
        self.lastSevenDays = lastSevenDays
        self.daily = daily
    }

    /// Average of the six days before today, for comparing today against.
    public var previousDailyAverage: Double? {
        guard let daily, daily.count > 1 else { return nil }
        let previous = daily.dropLast()
        let average = Double(previous.reduce(0, +)) / Double(previous.count)
        return average > 0 ? average : nil
    }

    public static func summing(_ events: [TokenEvent], now: Date = Date(), calendar: Calendar = .current) -> TokenTotals {
        let startOfToday = calendar.startOfDay(for: now)
        guard let start = calendar.date(byAdding: .day, value: -6, to: startOfToday) else { return TokenTotals() }
        var totals = TokenTotals(daily: Array(repeating: 0, count: 7))
        for event in events where event.timestamp >= start && event.timestamp <= now {
            totals.lastSevenDays = totals.lastSevenDays + event.counts
            if event.timestamp >= startOfToday { totals.today = totals.today + event.counts }
            let day = calendar.dateComponents([.day], from: start, to: calendar.startOfDay(for: event.timestamp)).day ?? 0
            if (0..<7).contains(day) { totals.daily?[day] += event.counts.total }
        }
        return totals
    }
}

public struct TokenEvent: Hashable, Sendable {
    public var timestamp: Date
    public var counts: TokenCounts
    /// Identifies a Claude message so it's counted once even if several transcripts log it.
    public var dedupeKey: String?
}

/// Reads token usage from the logs Claude Code and Codex write locally.
public enum TokenLogParser {
    /// One Claude Code transcript (`~/.claude/projects/*/*.jsonl`). Each assistant message carries
    /// `message.usage`; streamed messages repeat it, so events are deduped by message and request id.
    public static func claudeCodeEvents(_ data: Data) -> [TokenEvent] {
        var events: [TokenEvent] = []
        var seen = Set<String>()
        for line in lines(data, containing: "\"usage\"") {
            guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let message = json["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any],
                  let timestamp = DateParsing.iso8601(json["timestamp"] as? String)
            else { continue }
            if (message["model"] as? String) == "<synthetic>" { continue }

            let id = "\(message["id"] as? String ?? "")|\(json["requestId"] as? String ?? "")"
            let key = id == "|" ? nil : id
            if let key, !seen.insert(key).inserted { continue }

            func int(_ name: String) -> Int { ClaudeUsageParser.number(usage[name]).map(Int.init) ?? 0 }
            let counts = TokenCounts(
                input: int("input_tokens"),
                output: int("output_tokens"),
                cacheRead: int("cache_read_input_tokens"),
                cacheWrite: int("cache_creation_input_tokens")
            )
            if counts.total > 0 { events.append(TokenEvent(timestamp: timestamp, counts: counts, dedupeKey: key)) }
        }
        return events
    }

    /// One Codex session (`$CODEX_HOME/sessions/**/rollout-*.jsonl`). `token_count` events carry the
    /// last turn's usage and a running total; repeats of the same running total are skipped.
    public static func codexEvents(_ data: Data) -> [TokenEvent] {
        var events: [TokenEvent] = []
        var lastTotal: Int?
        for line in lines(data, containing: "token_count") {
            guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let payload = json["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count",
                  let info = payload["info"] as? [String: Any],
                  let last = info["last_token_usage"] as? [String: Any],
                  let timestamp = DateParsing.iso8601(json["timestamp"] as? String)
            else { continue }

            let runningTotal = ((info["total_token_usage"] as? [String: Any])?["total_tokens"]).flatMap(ClaudeUsageParser.number).map(Int.init)
            if let runningTotal, runningTotal == lastTotal { continue }
            lastTotal = runningTotal

            func int(_ name: String) -> Int { ClaudeUsageParser.number(last[name]).map(Int.init) ?? 0 }
            // OpenAI counts cached tokens inside input_tokens.
            let cached = int("cached_input_tokens")
            let counts = TokenCounts(
                input: max(0, int("input_tokens") - cached),
                output: int("output_tokens"),
                cacheRead: cached,
                cacheWrite: int("cache_write_input_tokens")
            )
            if counts.total > 0 { events.append(TokenEvent(timestamp: timestamp, counts: counts)) }
        }
        return events
    }

    private static func lines(_ data: Data, containing marker: String) -> [Data] {
        let needle = Data(marker.utf8)
        return data.split(separator: UInt8(ascii: "\n")).filter { $0.range(of: needle) != nil }.map { Data($0) }
    }
}

/// Scans log folders for the last seven days, re-reading only files that changed since last time.
public actor TokenLogScanner {
    private struct CachedFile {
        var modified: Date
        var size: Int
        var events: [TokenEvent]
    }

    private var cache: [String: CachedFile] = [:]

    public init() {}

    public static var claudeCodeProjects: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    }

    public static func codexSessions(authFilePath: String) -> URL {
        URL(fileURLWithPath: authFilePath).deletingLastPathComponent().appendingPathComponent("sessions")
    }

    public func claudeCodeTotals(now: Date = Date()) -> TokenTotals {
        var seen = Set<String>()
        let events = events(in: Self.claudeCodeProjects, now: now, parse: TokenLogParser.claudeCodeEvents)
            // Resumed sessions can repeat a message in a second transcript.
            .filter { event in event.dedupeKey.map { seen.insert($0).inserted } ?? true }
        return TokenTotals.summing(events, now: now)
    }

    public func codexTotals(authFilePath: String, now: Date = Date()) -> TokenTotals {
        let root = Self.codexSessions(authFilePath: authFilePath)
        return TokenTotals.summing(events(in: root, now: now, parse: TokenLogParser.codexEvents), now: now)
    }

    private func events(in root: URL, now: Date, parse: (Data) -> [TokenEvent]) -> [TokenEvent] {
        let cutoff = now.addingTimeInterval(-8 * 86_400)
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        else { return [] }

        var events: [TokenEvent] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  let modified = values.contentModificationDate, modified >= cutoff
            else { continue }
            let size = values.fileSize ?? 0
            if let cached = cache[url.path], cached.modified == modified, cached.size == size {
                events += cached.events
                continue
            }
            guard let data = FileManager.default.contents(atPath: url.path) else { continue }
            let parsed = parse(data)
            cache[url.path] = CachedFile(modified: modified, size: size, events: parsed)
            events += parsed
        }
        return events
    }
}
