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
        #expect(ClaudeUsageParser.planName(subscriptionType: "max", rateLimitTier: "default_claude_max_20x") == "Ultra")
        #expect(ClaudeUsageParser.planName(subscriptionType: "max", rateLimitTier: "default_claude_max_5x") == "Max")
        #expect(ClaudeUsageParser.planName(subscriptionType: "pro", rateLimitTier: nil) == "Pro")
        #expect(ClaudeUsageParser.planName(subscriptionType: "ultra", rateLimitTier: "default_claude_ultra") == "Ultra")
        #expect(ClaudeUsageParser.planName(subscriptionType: nil, rateLimitTier: nil) == nil)
    }

    @Test func organizationsDropApiOnlyAndPreferPaid() throws {
        let json = #"""
        [{"uuid":"api","name":"API","capabilities":["api"]},
         {"uuid":"team","name":"Acme","capabilities":["chat","raven"]},
         {"uuid":"max","name":"me@example.com's Organization","capabilities":["chat","claude_max"]}]
        """#
        let orgs = try ClaudeOrganization.parseList(Data(json.utf8))
        #expect(orgs.map(\.id) == ["team", "max"])
        #expect(orgs.map(\.plan) == ["Team", "Max"])
        #expect(orgs[1].displayName == "me@example.com")
        #expect(ClaudeOrganization.preferred(orgs)?.id == "max")
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

@Suite struct SavedAccountTests {
    @Test func skipsRemovedSourcesWithoutLosingTheRest() throws {
        let kept = AccountConfig(name: "Work", source: .claudeWeb(organizationID: "org"))
        let keptJSON = String(decoding: try JSONEncoder().encode(kept), as: UTF8.self)
        let json = #"""
        [{"id":"7D1F1C7E-0C1B-4B39-9F5D-0A1A7B7C0001","name":"Claude Code","source":{"claudeCode":{}},"isEnabled":true},
         \#(keptJSON),
         {"id":"7D1F1C7E-0C1B-4B39-9F5D-0A1A7B7C0002","name":"Codex","source":{"codexCLI":{"authFilePath":"/x"}},"isEnabled":true}]
        """#
        let saved = AccountConfig.decodeSaved(Data(json.utf8))
        #expect(saved.accounts == [kept])
        #expect(saved.skipped == 2)
    }

    @Test func currentListRoundTrips() throws {
        let accounts = [AccountConfig(name: "a", source: .chatGPTWeb), AccountConfig(name: "b", source: .anthropicAdmin)]
        let saved = AccountConfig.decodeSaved(try JSONEncoder().encode(accounts))
        #expect(saved.accounts == accounts)
        #expect(saved.skipped == 0)
    }
}

@Suite struct RenewSignInTests {
    private func snapshot(_ account: AccountConfig, identity: String, plan: String) -> [UUID: AccountSnapshot] {
        [account.id: AccountSnapshot(id: account.id, accountName: account.name, provider: account.provider, plan: plan, identity: identity)]
    }

    @Test func claudeMatchesByOrganization() {
        let account = AccountConfig(name: "Renamed", source: .claudeWeb(organizationID: "org"))
        let usage = ProviderUsage(windows: [], plan: "Max", identity: "Someone")
        #expect(AccountConfig.existing(in: [account], source: .claudeWeb(organizationID: "org"), usage: usage, snapshots: [:]) == account)
        #expect(AccountConfig.existing(in: [account], source: .claudeWeb(organizationID: "other"), usage: usage, snapshots: [:]) == nil)
    }

    @Test func chatGPTMatchesByIdentityAndPlan() {
        let account = AccountConfig(name: "Mine", source: .chatGPTWeb)
        let snapshots = snapshot(account, identity: "me@example.com", plan: "Pro")
        let same = ProviderUsage(windows: [], plan: "Pro", identity: "me@example.com")
        let otherWorkspace = ProviderUsage(windows: [], plan: "Team", identity: "me@example.com")
        let otherEmail = ProviderUsage(windows: [], plan: "Pro", identity: "you@example.com")
        #expect(AccountConfig.existing(in: [account], source: .chatGPTWeb, usage: same, snapshots: snapshots) == account)
        #expect(AccountConfig.existing(in: [account], source: .chatGPTWeb, usage: otherWorkspace, snapshots: snapshots) == nil)
        #expect(AccountConfig.existing(in: [account], source: .chatGPTWeb, usage: otherEmail, snapshots: snapshots) == nil)
    }

    @Test func olderClaudeAccountWithoutOrganizationMatchesByIdentity() {
        let account = AccountConfig(name: "Old", source: .claudeWeb(organizationID: nil))
        let snapshots = snapshot(account, identity: "me@example.com", plan: "Max")
        let usage = ProviderUsage(windows: [], plan: "Max", identity: "me@example.com")
        #expect(AccountConfig.existing(in: [account], source: .claudeWeb(organizationID: "org"), usage: usage, snapshots: snapshots) == account)
    }

    @Test func neverMatchesAcrossProviders() {
        let account = AccountConfig(name: "Mine", source: .chatGPTWeb)
        let snapshots = snapshot(account, identity: "me@example.com", plan: "Pro")
        let usage = ProviderUsage(windows: [], plan: "Pro", identity: "me@example.com")
        #expect(AccountConfig.existing(in: [account], source: .claudeWeb(organizationID: "org"), usage: usage, snapshots: snapshots) == nil)
    }
}
