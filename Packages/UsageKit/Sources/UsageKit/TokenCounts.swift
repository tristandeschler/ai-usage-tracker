import Foundation

/// Token counts as both admin APIs report them. `input` excludes cached tokens.
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
    /// Today plus the six days before it.
    public var lastSevenDays = TokenCounts()
    /// Total tokens per UTC day, oldest first, ending today. Optional so older caches still decode.
    public var daily: [Int]?

    public init(today: TokenCounts = TokenCounts(), lastSevenDays: TokenCounts = TokenCounts(), daily: [Int]? = nil) {
        self.today = today
        self.lastSevenDays = lastSevenDays
        self.daily = daily
    }
}
