import Foundation
import Testing
@testable import UsageKit

func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

@Suite struct ClaudeParserTests {
    @Test func parsesLimitsArray() throws {
        let usage = try ClaudeUsageParser.parse(try fixture("claude-oauth-usage"))

        #expect(usage.windows.map(\.id) == ["weekly", "weekly:Fable"])
        let weekly = try #require(usage.windows.first)
        #expect(weekly.usedPercent == 43)
        #expect(weekly.kind == .weekly)
        let expected = try #require(ISO8601DateFormatter().date(from: "2026-11-04T16:00:00Z"))
        #expect(abs(try #require(weekly.resetsAt).timeIntervalSince(expected)) < 1)
        #expect(usage.windows[1].label == "Weekly · Fable")
    }

    @Test func parsesLegacyShapeWithSession() throws {
        let usage = try ClaudeUsageParser.parse(try fixture("claude-legacy-usage"))

        #expect(usage.windows.map(\.id) == ["session", "weekly", "weekly:Opus"])
        #expect(usage.windows[0].usedPercent == 100)
        #expect(usage.windows[0].isExhausted)
        #expect(usage.windows[1].usedPercent == 61.5)
        #expect(usage.windows[1].resetsAt != nil)
        #expect(usage.windows[2].resetsAt == nil)
    }

    @Test func planNames() {
        #expect(ClaudeUsageParser.planName(subscriptionType: "max", rateLimitTier: "default_claude_max_20x") == "Max")
        #expect(ClaudeUsageParser.planName(subscriptionType: "max", rateLimitTier: "default_claude_max_5x") == "Max")
        #expect(ClaudeUsageParser.planName(subscriptionType: "pro", rateLimitTier: nil) == "Pro")
        #expect(ClaudeUsageParser.planName(subscriptionType: "ultra", rateLimitTier: "default_claude_ultra") == "Max")
        #expect(ClaudeUsageParser.planName(subscriptionType: nil, rateLimitTier: nil) == nil)
    }

    @Test func parsesClaudeCodeCredentials() throws {
        let json = #"{"claudeAiOauth":{"accessToken":"tok","refreshToken":"r","expiresAt":1793989910000,"subscriptionType":"max","rateLimitTier":"default_claude_max_20x"}}"#
        let creds = try ClaudeCodeCredentials.parse(Data(json.utf8))
        #expect(creds.accessToken == "tok")
        #expect(creds.expiresAt == Date(timeIntervalSince1970: 1_793_989_910))
        #expect(creds.subscriptionType == "max")
    }

    @Test func preferredOrganizationPicksPaidPlan() {
        let orgs: [[String: Any]] = [
            ["uuid": "api", "capabilities": ["api"]],
            ["uuid": "free", "capabilities": ["chat"]],
            ["uuid": "max", "capabilities": ["chat", "claude_max"]],
        ]
        #expect(UsageFetcher.preferredOrganization(orgs)?["uuid"] as? String == "max")
    }
}

@Suite struct CodexParserTests {
    @Test func parsesWeeklyOnlyPlan() throws {
        let usage = try CodexUsageParser.parse(try fixture("codex-usage"))

        #expect(usage.plan == "Pro Lite")
        #expect(usage.identity == "me@example.com")
        #expect(usage.limitReached == false)
        #expect(usage.windows.count == 1)
        #expect(usage.windows[0].id == "weekly")
        #expect(usage.windows[0].usedPercent == 0)
        #expect(usage.windows[0].resetsAt == Date(timeIntervalSince1970: 1_793_989_910))
    }

    @Test func parsesLimitedPlanWithModelLimits() throws {
        let usage = try CodexUsageParser.parse(try fixture("codex-usage-limited"))

        #expect(usage.limitReached)
        #expect(usage.windows.map(\.id) == ["session", "weekly", "weekly:GPT-5.3-Codex-Spark"])
        #expect(usage.windows.map(\.usedPercent) == [100, 72, 30])
        #expect(usage.windows[2].label == "Weekly · GPT-5.3-Codex-Spark")
    }

    @Test func parsesAuthFile() throws {
        // Header/payload only; the parser never verifies signatures.
        let payload = Data(#"{"email":"me@example.com","exp":1}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
        let idToken = "e30.\(payload).sig"
        let json = #"{"auth_mode":"chatgpt","tokens":{"access_token":"e30.\#(payload).sig","refresh_token":"r","id_token":"\#(idToken)","account_id":"acct"}}"#
        let auth = try CodexAuthFile.parse(Data(json.utf8))
        #expect(auth.accountID == "acct")
        #expect(auth.email == "me@example.com")
        #expect(auth.isExpired)
    }

    @Test func authFileWithoutTokensIsNotSignedIn() {
        #expect(throws: UsageError.self) {
            try CodexAuthFile.parse(Data(#"{"OPENAI_API_KEY":"sk-..."}"#.utf8))
        }
    }
}

@Suite struct CookieHeaderTests {
    @Test func mergesRotatedCookies() throws {
        let url = URL(string: "https://chatgpt.com/api/auth/session")!
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [
            "Set-Cookie": "session=new; Path=/; Secure",
        ]))
        let merged = CookieHeader.merging("a=1; session=old", response: response)
        #expect(merged == "a=1; session=new")
        #expect(CookieHeader.merging("a=1; session=new", response: response) == nil)
    }
}
