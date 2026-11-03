import Foundation
import Testing
@testable import UsageKit

@Suite struct AppReleaseTests {
    @Test func versionComparison() {
        #expect(AppRelease.isNewer("0.2.0", than: "0.1.0"))
        #expect(AppRelease.isNewer("0.10.0", than: "0.9.1"))
        #expect(AppRelease.isNewer("1.0", than: "0.99.99"))
        #expect(!AppRelease.isNewer("0.1.0", than: "0.1.0"))
        #expect(!AppRelease.isNewer("0.1", than: "0.1.0"))
        #expect(!AppRelease.isNewer("0.1.0", than: "0.2.0"))
    }

    @Test func parsesLatestRelease() throws {
        let json = #"""
        {"tag_name":"v0.2.0","draft":false,"prerelease":false,"body":"Notes","html_url":"https://github.com/o/r/releases/tag/v0.2.0",
         "assets":[{"name":"TokenTracker-0.2.0.zip.sha256","browser_download_url":"https://example.com/a.zip.sha256"},
                   {"name":"TokenTracker-0.2.0.zip","browser_download_url":"https://example.com/a.zip"}]}
        """#
        let release = try #require(AppRelease.parseLatest(Data(json.utf8)))
        #expect(release.version == "0.2.0")
        #expect(release.zipURL.absoluteString == "https://example.com/a.zip")
        #expect(release.checksumURL?.absoluteString == "https://example.com/a.zip.sha256")
    }

    @Test func skipsPrereleasesAndReleasesWithoutZip() {
        #expect(AppRelease.parseLatest(Data(#"{"tag_name":"v1","prerelease":true,"html_url":"https://x","assets":[]}"#.utf8)) == nil)
        #expect(AppRelease.parseLatest(Data(#"{"tag_name":"v1","html_url":"https://x","assets":[]}"#.utf8)) == nil)
    }
}
