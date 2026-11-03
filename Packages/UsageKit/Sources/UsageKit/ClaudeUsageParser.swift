import Foundation

/// Parses the usage payload shared by `api.anthropic.com/api/oauth/usage` and
/// `claude.ai/api/organizations/{org}/usage`.
///
/// The payload is loosely typed and grows new codenamed keys often, so this reads it
/// as a dictionary and only picks out the fields it understands.
public enum ClaudeUsageParser {
    public static func parse(_ data: Data) throws -> ProviderUsage {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError.invalidResponse("Claude usage was not a JSON object")
        }
        return parse(json)
    }

    static func parse(_ json: [String: Any]) -> ProviderUsage {
        var windows: [UsageWindow] = []

        if let fiveHour = window(json["five_hour"]) {
            windows.append(UsageWindow(
                id: "session", label: "5-hour session", kind: .session,
                usedPercent: fiveHour.percent, resetsAt: fiveHour.resetsAt
            ))
        }

        if let limits = json["limits"] as? [[String: Any]], !limits.isEmpty {
            windows += limits.compactMap(limitWindow)
        } else {
            // Older shape: flat `seven_day*` keys.
            let legacy: [(key: String, id: String, label: String, kind: UsageWindow.Kind)] = [
                ("seven_day", "weekly", "Weekly", .weekly),
                ("seven_day_opus", "weekly:Opus", "Weekly · Opus", .weeklyModel),
                ("seven_day_sonnet", "weekly:Sonnet", "Weekly · Sonnet", .weeklyModel),
            ]
            for entry in legacy {
                if let w = window(json[entry.key]) {
                    windows.append(UsageWindow(
                        id: entry.id, label: entry.label, kind: entry.kind,
                        usedPercent: w.percent, resetsAt: w.resetsAt
                    ))
                }
            }
        }

        // Drop duplicates (e.g. a session entry in both `five_hour` and `limits`), keeping the first.
        var seen = Set<String>()
        windows = windows.filter { seen.insert($0.id).inserted }

        return ProviderUsage(windows: windows)
    }

    private static func window(_ value: Any?) -> (percent: Double, resetsAt: Date?)? {
        guard let dict = value as? [String: Any], let percent = number(dict["utilization"]) else { return nil }
        return (percent, DateParsing.iso8601(dict["resets_at"] as? String))
    }

    private static func limitWindow(_ entry: [String: Any]) -> UsageWindow? {
        guard let percent = number(entry["percent"]) ?? number(entry["utilization"]) else { return nil }
        let kind = (entry["kind"] as? String) ?? ""
        let group = (entry["group"] as? String) ?? ""
        let resetsAt = DateParsing.iso8601(entry["resets_at"] as? String)
        let model = ((entry["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String

        if group == "session" || kind.contains("session") || kind.contains("five_hour") {
            return UsageWindow(id: "session", label: "5-hour session", kind: .session, usedPercent: percent, resetsAt: resetsAt)
        }
        if let model {
            return UsageWindow(
                id: "weekly:\(model)", label: "Weekly · \(model)", kind: .weeklyModel,
                usedPercent: percent, resetsAt: resetsAt
            )
        }
        if group == "weekly" || kind.hasPrefix("weekly") {
            return UsageWindow(id: "weekly", label: "Weekly", kind: .weekly, usedPercent: percent, resetsAt: resetsAt)
        }
        let name = kind.isEmpty ? "Limit" : kind.replacingOccurrences(of: "_", with: " ").capitalized
        return UsageWindow(id: "other:\(kind)", label: name, kind: .other, usedPercent: percent, resetsAt: resetsAt)
    }

    static func number(_ value: Any?) -> Double? {
        switch value {
        case let n as NSNumber: n.doubleValue
        case let s as String: Double(s)
        default: nil
        }
    }

    /// Turns `subscriptionType`/`rateLimitTier` from Claude Code's credentials into e.g. "Ultra".
    public static func planName(subscriptionType: String?, rateLimitTier: String?) -> String? {
        // The 20x tier is now called Ultra, though its tier string still says max_20x. Max 5x stays Max.
        let type = subscriptionType?.lowercased() ?? ""
        let tier = rateLimitTier?.lowercased() ?? ""
        if type == "ultra" || tier.contains("ultra") || tier.contains("max_20x") { return "Ultra" }
        if type == "max" || tier.contains("max_") { return "Max" }
        guard let type = subscriptionType, !type.isEmpty else { return nil }
        return type.prefix(1).uppercased() + type.dropFirst()
    }
}

enum DateParsing {
    // ISO8601DateFormatter is documented as thread-safe.
    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Parses ISO 8601 timestamps, including microsecond precision like `2026-11-04T16:00:00.239197+00:00`.
    static func iso8601(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        if let date = fractional.date(from: string) ?? plain.date(from: string) { return date }
        // ISO8601DateFormatter is picky about >3 fractional digits on some OS versions; strip them.
        let stripped = string.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return plain.date(from: stripped)
    }
}
