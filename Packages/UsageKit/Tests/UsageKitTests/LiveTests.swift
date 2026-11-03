import Foundation
import Testing
@testable import UsageKit

/// Hits the real endpoints with this Mac's Claude Code and Codex logins.
/// Run with `LIVE=1 swift test --filter LiveTests`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["LIVE"] != nil))
struct LiveTests {
    let fetcher = UsageFetcher(http: URLSession.isolated, secrets: MemorySecretStore(), claudeCode: ClaudeCodeKeychainReader())

    @Test func claudeCode() async throws {
        let snapshot = await fetcher.snapshot(for: AccountConfig(name: "Claude Code", source: .claudeCode))
        print("Claude:", snapshot.plan ?? "-", snapshot.windows.map { "\($0.label) \($0.usedPercent)%" }, snapshot.error ?? "")
        #expect(snapshot.error == nil)
        #expect(!snapshot.windows.isEmpty)
    }

    @Test func codexCLI() async throws {
        let snapshot = await fetcher.snapshot(for: AccountConfig(name: "Codex", source: .codexCLI(authFilePath: CodexAuthFile.defaultPath())))
        print("Codex:", snapshot.plan ?? "-", snapshot.identity ?? "-", snapshot.windows.map { "\($0.label) \($0.usedPercent)%" }, snapshot.error ?? "")
        #expect(snapshot.error == nil)
        #expect(!snapshot.windows.isEmpty)
    }
}
