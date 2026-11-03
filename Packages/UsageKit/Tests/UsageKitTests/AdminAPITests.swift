import Foundation
import Testing
@testable import UsageKit

@Suite struct AdminAPITests {
    let now = ISO8601DateFormatter().date(from: "2026-11-03T15:00:00Z")!
    var start: Date { AdminAPIUsage.range(now: now).start }

    @Test func rangeStartsSixUTCDaysAgo() {
        #expect(start == ISO8601DateFormatter().date(from: "2026-10-28T00:00:00Z"))
    }

    @Test func anthropicTokensAndSpend() throws {
        let tokens = #"""
        {"data":[
          {"starting_at":"2026-11-02T00:00:00Z","ending_at":"2026-11-03T00:00:00Z","results":[
            {"uncached_input_tokens":100,"cache_creation":{"ephemeral_5m_input_tokens":10,"ephemeral_1h_input_tokens":5},"cache_read_input_tokens":1000,"output_tokens":50}]},
          {"starting_at":"2026-11-03T00:00:00Z","ending_at":"2026-11-04T00:00:00Z","results":[
            {"uncached_input_tokens":7,"cache_creation":null,"cache_read_input_tokens":0,"output_tokens":3}]}
        ],"has_more":false,"next_page":null}
        """#
        let perDay = try AdminAPIUsage.parseAnthropicTokens([Data(tokens.utf8)], start: start)
        #expect(perDay[5] == TokenCounts(input: 100, output: 50, cacheRead: 1000, cacheWrite: 15))
        #expect(perDay[6].total == 10)

        let totals = AdminAPIUsage.totals(perDay)
        #expect(totals.today.total == 10)
        #expect(totals.lastSevenDays.total == 1175)
        #expect(totals.daily == [0, 0, 0, 0, 0, 1165, 10])

        let costs = #"{"data":[{"starting_at":"2026-11-03T00:00:00Z","results":[{"currency":"USD","amount":"1234.5"},{"currency":"USD","amount":"100"}]}],"has_more":false}"#
        let spend = SpendTotals(daily: try AdminAPIUsage.parseAnthropicSpend([Data(costs.utf8)], start: start))
        #expect(spend.today == 13.345)
        #expect(spend.lastSevenDays == 13.345)
    }

    @Test func openAITokensAndSpend() throws {
        let day = Int(ISO8601DateFormatter().date(from: "2026-11-03T00:00:00Z")!.timeIntervalSince1970)
        let tokens = #"{"object":"page","data":[{"object":"bucket","start_time":\#(day),"end_time":\#(day + 86400),"results":[{"input_tokens":1000,"input_cached_tokens":400,"output_tokens":200,"num_model_requests":3}]}],"has_more":false}"#
        let perDay = try AdminAPIUsage.parseOpenAITokens([Data(tokens.utf8)], start: start)
        #expect(perDay[6] == TokenCounts(input: 600, output: 200, cacheRead: 400))

        let costs = #"{"data":[{"start_time":\#(day),"results":[{"amount":{"value":0.42,"currency":"usd"},"line_item":"gpt-6"}]}],"has_more":false}"#
        #expect(try AdminAPIUsage.parseOpenAISpend([Data(costs.utf8)], start: start)[6] == 0.42)
    }

    @Test func paginationCursor() {
        #expect(AdminAPIUsage.nextPage(Data(#"{"data":[],"has_more":true,"next_page":"abc"}"#.utf8)) == "abc")
        #expect(AdminAPIUsage.nextPage(Data(#"{"data":[],"has_more":false,"next_page":null}"#.utf8)) == nil)
    }
}
