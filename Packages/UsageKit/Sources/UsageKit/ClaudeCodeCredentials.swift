import Foundation

public struct ClaudeCodeCredentials: Sendable, Equatable {
    public var accessToken: String
    public var expiresAt: Date?
    public var subscriptionType: String?
    public var rateLimitTier: String?

    public init(accessToken: String, expiresAt: Date? = nil, subscriptionType: String? = nil, rateLimitTier: String? = nil) {
        self.accessToken = accessToken
        self.expiresAt = expiresAt
        self.subscriptionType = subscriptionType
        self.rateLimitTier = rateLimitTier
    }

    /// Parses Claude Code's credential JSON (`{"claudeAiOauth": {...}}`).
    public static func parse(_ data: Data) throws -> ClaudeCodeCredentials {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty
        else {
            throw UsageError.notSignedIn("Run `claude` and sign in with your Claude subscription.")
        }
        let expiresAt = ClaudeUsageParser.number(oauth["expiresAt"]).map { Date(timeIntervalSince1970: $0 / 1000) }
        return ClaudeCodeCredentials(
            accessToken: token,
            expiresAt: expiresAt,
            subscriptionType: oauth["subscriptionType"] as? String,
            rateLimitTier: oauth["rateLimitTier"] as? String
        )
    }
}

public protocol ClaudeCodeCredentialProvider: Sendable {
    func load() throws -> ClaudeCodeCredentials
}

#if os(macOS)
/// Reads the credentials Claude Code keeps for its signed-in account.
///
/// Claude Code writes its Keychain item with `/usr/bin/security`, so reading it the same way
/// avoids a Keychain access prompt for TokenTracker. We never write to it: Claude Code owns
/// refreshing that token, and rotating it from here would sign Claude Code out.
public struct ClaudeCodeKeychainReader: ClaudeCodeCredentialProvider {
    public static let service = "Claude Code-credentials"

    public init() {}

    public func load() throws -> ClaudeCodeCredentials {
        if let data = try? readKeychain(), !data.isEmpty {
            return try ClaudeCodeCredentials.parse(data)
        }
        // Linux-style fallback that some setups still use.
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json")
        if let data = try? Data(contentsOf: file) {
            return try ClaudeCodeCredentials.parse(data)
        }
        throw UsageError.notSignedIn("Run `claude` and sign in with your Claude subscription.")
    }

    private func readKeychain() throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", Self.service, "-w"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return Data() }
        return data
    }
}
#endif
