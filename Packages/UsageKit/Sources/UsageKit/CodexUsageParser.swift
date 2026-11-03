import Foundation

/// Parses `chatgpt.com/backend-api/wham/usage`, which reports ChatGPT/Codex plan limits.
public enum CodexUsageParser {
    public static func parse(_ data: Data) throws -> ProviderUsage {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError.invalidResponse("ChatGPT usage was not a JSON object")
        }
        return parse(json)
    }

    static func parse(_ json: [String: Any]) -> ProviderUsage {
        var windows: [UsageWindow] = []
        var limitReached = false

        if let rateLimit = json["rate_limit"] as? [String: Any] {
            windows += rateLimitWindows(rateLimit, prefix: nil)
            limitReached = (rateLimit["limit_reached"] as? Bool) == true || (rateLimit["allowed"] as? Bool) == false
        }

        if let additional = json["additional_rate_limits"] as? [[String: Any]] {
            for entry in additional {
                guard let rateLimit = entry["rate_limit"] as? [String: Any] else { continue }
                let name = (entry["limit_name"] as? String) ?? (entry["metered_feature"] as? String) ?? "Model"
                windows += rateLimitWindows(rateLimit, prefix: name)
            }
        }

        return ProviderUsage(
            windows: windows,
            plan: planName(json["plan_type"] as? String),
            identity: json["email"] as? String,
            limitReached: limitReached
        )
    }

    private static func rateLimitWindows(_ rateLimit: [String: Any], prefix: String?) -> [UsageWindow] {
        ["primary_window", "secondary_window"].compactMap { key in
            guard let window = rateLimit[key] as? [String: Any],
                  let percent = ClaudeUsageParser.number(window["used_percent"])
            else { return nil }

            let seconds = ClaudeUsageParser.number(window["limit_window_seconds"]).map(Int.init)
            var resetsAt: Date?
            if let epoch = ClaudeUsageParser.number(window["reset_at"]) {
                resetsAt = Date(timeIntervalSince1970: epoch)
            } else if let after = ClaudeUsageParser.number(window["reset_after_seconds"]) {
                resetsAt = Date().addingTimeInterval(after)
            }

            let (id, label, kind) = describe(windowSeconds: seconds)
            if let prefix {
                return UsageWindow(
                    id: "\(id):\(prefix)", label: "\(label) · \(prefix)", kind: .weeklyModel,
                    usedPercent: percent, resetsAt: resetsAt
                )
            }
            return UsageWindow(id: id, label: label, kind: kind, usedPercent: percent, resetsAt: resetsAt)
        }
    }

    private static func describe(windowSeconds: Int?) -> (String, String, UsageWindow.Kind) {
        switch windowSeconds {
        case 18_000: ("session", "Session (5h)", .session)
        case 604_800: ("weekly", "Weekly", .weekly)
        case let s? where s % 86_400 == 0: ("window:\(s)", "\(s / 86_400)-day", .other)
        case let s? where s % 3_600 == 0: ("window:\(s)", "\(s / 3_600)h", .other)
        default: ("window:\(windowSeconds ?? 0)", "Limit", .other)
        }
    }

    static func planName(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        switch raw {
        case "prolite": return "Pro Lite"
        case "free_workspace": return "Free Workspace"
        default: return raw.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}
