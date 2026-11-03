import Foundation

/// A Codex CLI `auth.json` (`$CODEX_HOME/auth.json`, default `~/.codex/auth.json`), read-only.
public struct CodexAuthFile: Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String?
    public var idToken: String?
    public var accountID: String?

    public static func defaultPath() -> String {
        if let home = ProcessInfo.processInfo.environment["CODEX_HOME"], !home.isEmpty {
            return (home as NSString).appendingPathComponent("auth.json")
        }
        return (NSHomeDirectory() as NSString).appendingPathComponent(".codex/auth.json")
    }

    public static func load(path: String) throws -> CodexAuthFile {
        guard let data = FileManager.default.contents(atPath: path) else {
            throw UsageError.notSignedIn("No Codex login at \(path). Run `codex login`.")
        }
        return try parse(data)
    }

    public static func parse(_ data: Data) throws -> CodexAuthFile {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = json["tokens"] as? [String: Any],
              let access = tokens["access_token"] as? String, !access.isEmpty
        else {
            throw UsageError.notSignedIn("Codex is not signed in with ChatGPT. Run `codex login`.")
        }
        return CodexAuthFile(
            accessToken: access,
            refreshToken: tokens["refresh_token"] as? String,
            idToken: tokens["id_token"] as? String,
            accountID: tokens["account_id"] as? String
        )
    }

    public var email: String? {
        idToken.flatMap { JWT.claims($0)?["email"] as? String }
    }

    public var isExpired: Bool {
        guard let expiry = JWT.expiry(accessToken) else { return false }
        return expiry < Date().addingTimeInterval(60)
    }
}
