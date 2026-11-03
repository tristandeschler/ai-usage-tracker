import Foundation

/// A Codex CLI `auth.json` (`$CODEX_HOME/auth.json`, default `~/.codex/auth.json`).
public struct CodexAuthFile: Sendable, Equatable {
    public static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    public static let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!

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

    /// Refreshes the tokens and writes them back to `path`, preserving any other keys,
    /// the same way the Codex CLI does.
    public func refreshed(writingTo path: String, http: any HTTPClient) async throws -> CodexAuthFile {
        guard let refreshToken else { throw UsageError.expired("Run `codex login` again.") }

        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_id": Self.clientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "scope": "openid profile email",
        ])
        let (data, response) = try await http.send(request)
        guard response.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String
        else {
            throw UsageError.expired("Codex refresh failed (HTTP \(response.statusCode)). Run `codex login` again.")
        }

        var updated = self
        updated.accessToken = access
        updated.refreshToken = (json["refresh_token"] as? String) ?? refreshToken
        updated.idToken = (json["id_token"] as? String) ?? idToken
        try updated.write(to: path)
        return updated
    }

    func write(to path: String) throws {
        var root = (FileManager.default.contents(atPath: path))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        var tokens = (root["tokens"] as? [String: Any]) ?? [:]
        tokens["access_token"] = accessToken
        tokens["refresh_token"] = refreshToken
        tokens["id_token"] = idToken
        if let accountID { tokens["account_id"] = accountID }
        root["tokens"] = tokens
        root["last_refresh"] = ISO8601DateFormatter().string(from: Date())
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }
}
