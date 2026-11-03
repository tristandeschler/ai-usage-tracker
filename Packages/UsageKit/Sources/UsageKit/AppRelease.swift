import Foundation

/// A published release of Token Tracker, from the GitHub releases API.
public struct AppRelease: Equatable, Sendable {
    public var version: String
    public var notes: String
    public var pageURL: URL
    public var zipURL: URL
    public var checksumURL: URL?

    /// Parses `GET /repos/{owner}/{repo}/releases/latest`. Drafts, prereleases and releases
    /// without a zip are skipped.
    public static func parseLatest(_ data: Data) -> AppRelease? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["draft"] as? Bool != true, json["prerelease"] as? Bool != true,
              let tag = json["tag_name"] as? String,
              let page = (json["html_url"] as? String).flatMap(URL.init(string:)),
              let assets = json["assets"] as? [[String: Any]]
        else { return nil }

        func asset(_ matches: (String) -> Bool) -> URL? {
            assets.first { matches(($0["name"] as? String) ?? "") }
                .flatMap { $0["browser_download_url"] as? String }
                .flatMap(URL.init(string:))
        }
        guard let zip = asset({ $0.hasSuffix(".zip") }) else { return nil }
        return AppRelease(
            version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag,
            notes: (json["body"] as? String) ?? "",
            pageURL: page,
            zipURL: zip,
            checksumURL: asset { $0.hasSuffix(".zip.sha256") }
        )
    }

    /// Whether `version` is newer than `current`, comparing dotted numbers ("0.10.0" > "0.9.1").
    public static func isNewer(_ version: String, than current: String) -> Bool {
        let parse = { (v: String) in v.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 } }
        let a = parse(version), b = parse(current)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0, y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }
}
