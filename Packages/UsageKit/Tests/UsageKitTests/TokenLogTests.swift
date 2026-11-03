import Foundation
import Testing
@testable import UsageKit

@Suite struct TokenLogTests {
    @Test func claudeCodeDedupesStreamedMessages() {
        let log = """
        {"type":"user","timestamp":"2026-11-03T09:00:00.000Z","message":{"role":"user","content":"hi"}}
        {"type":"assistant","requestId":"req_1","timestamp":"2026-11-03T09:00:01.000Z","message":{"id":"msg_1","model":"claude-opus-5-5","usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":100,"cache_creation_input_tokens":20}}}
        {"type":"assistant","requestId":"req_1","timestamp":"2026-11-03T09:00:02.000Z","message":{"id":"msg_1","model":"claude-opus-5-5","usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":100,"cache_creation_input_tokens":20}}}
        {"type":"assistant","requestId":"req_2","timestamp":"2026-11-03T09:01:00.000Z","message":{"id":"msg_2","model":"<synthetic>","usage":{"input_tokens":0,"output_tokens":0}}}
        {"type":"assistant","requestId":"req_3","timestamp":"2026-11-03T09:02:00.000Z","message":{"id":"msg_3","model":"claude-opus-5-5","usage":{"input_tokens":1,"output_tokens":2}}}
        """
        let events = TokenLogParser.claudeCodeEvents(Data(log.utf8))
        #expect(events.map(\.counts.total) == [135, 3])
        #expect(events[0].counts == TokenCounts(input: 10, output: 5, cacheRead: 100, cacheWrite: 20))
        #expect(events[0].dedupeKey == "msg_1|req_1")
    }

    @Test func codexSplitsCachedInputAndSkipsRepeats() {
        let event = { (ts: String, total: Int, input: Int, cached: Int, output: Int) in
            #"{"timestamp":"\#(ts)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":\#(total)},"last_token_usage":{"input_tokens":\#(input),"cached_input_tokens":\#(cached),"output_tokens":\#(output),"total_tokens":\#(input + output)}}}}"#
        }
        let log = [
            event("2026-11-03T09:00:00.000Z", 1_100, 1_000, 400, 100),
            event("2026-11-03T09:00:01.000Z", 1_100, 1_000, 400, 100),  // repeated running total
            event("2026-11-03T09:05:00.000Z", 1_400, 250, 200, 50),
        ].joined(separator: "\n")
        let events = TokenLogParser.codexEvents(Data(log.utf8))
        #expect(events.count == 2)
        #expect(events[0].counts == TokenCounts(input: 600, output: 100, cacheRead: 400))
        #expect(events.map(\.counts.total) == [1_100, 300])
    }

    @Test func totalsSplitTodayAndWeek() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = ISO8601DateFormatter().date(from: "2026-11-03T12:00:00Z")!
        let at = { (iso: String, n: Int) in TokenEvent(timestamp: ISO8601DateFormatter().date(from: iso)!, counts: TokenCounts(output: n)) }
        let totals = TokenTotals.summing([
            at("2026-11-03T08:00:00Z", 5),   // today
            at("2026-11-02T23:00:00Z", 7),   // yesterday
            at("2026-10-28T09:00:00Z", 3),   // six days ago, the first day counted
            at("2026-10-27T23:00:00Z", 100), // seven days ago, not counted
        ], now: now, calendar: calendar)
        #expect(totals.today.total == 5)
        #expect(totals.lastSevenDays.total == 15)
        #expect(totals.daily == [3, 0, 0, 0, 0, 7, 5])
        #expect(totals.previousDailyAverage == 10.0 / 6)
    }

    @Test func claudeAppBreakdown() throws {
        let usage = try ClaudeUsageParser.parse(try fixture("claude-oauth-usage"))
        #expect(usage.appShares == [AppShare(name: "Claude Code", percent: 70), AppShare(name: "Chats", percent: 30)])
    }
}
