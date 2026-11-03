import Foundation

public protocol HTTPClient: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

extension URLSession: HTTPClient {
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UsageError.invalidResponse("not an HTTP response")
        }
        return (data, http)
    }

    /// A session that never stores cookies or caches responses, so each account's cookies stay
    /// isolated in the `Cookie` header we set by hand.
    public static let isolated: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config)
    }()
}

/// Helpers for the `Cookie` header we store per web-session account.
public enum CookieHeader {
    public static func make(from cookies: [HTTPCookie]) -> String {
        cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    public static func parse(_ header: String) -> [(name: String, value: String)] {
        header.split(separator: ";").compactMap { part in
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            guard let eq = trimmed.firstIndex(of: "=") else { return nil }
            return (String(trimmed[..<eq]), String(trimmed[trimmed.index(after: eq)...]))
        }
    }

    public static func value(named name: String, in header: String) -> String? {
        parse(header).first { $0.name == name }?.value
    }

    /// Applies `Set-Cookie` values from a response so rotating session cookies stay current.
    /// Returns nil when nothing changed.
    public static func merging(_ header: String, response: HTTPURLResponse) -> String? {
        guard let url = response.url,
              let fields = response.allHeaderFields as? [String: String]
        else { return nil }
        let updates = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
        guard !updates.isEmpty else { return nil }

        var pairs = parse(header)
        var changed = false
        for cookie in updates {
            let expired = cookie.expiresDate.map { $0 < Date() } ?? false
            if let index = pairs.firstIndex(where: { $0.name == cookie.name }) {
                if expired {
                    pairs.remove(at: index)
                    changed = true
                } else if pairs[index].value != cookie.value {
                    pairs[index].value = cookie.value
                    changed = true
                }
            } else if !expired {
                pairs.append((cookie.name, cookie.value))
                changed = true
            }
        }
        return changed ? pairs.map { "\($0.name)=\($0.value)" }.joined(separator: "; ") : nil
    }
}

enum JWT {
    /// Decodes a JWT payload without verifying it; used only to read `exp` and `email`.
    static func claims(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func expiry(_ token: String) -> Date? {
        guard let exp = ClaudeUsageParser.number(claims(token)?["exp"]) else { return nil }
        return Date(timeIntervalSince1970: exp)
    }
}
