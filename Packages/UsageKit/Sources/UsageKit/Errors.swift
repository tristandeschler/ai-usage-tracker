import Foundation

public enum UsageError: LocalizedError, Equatable, Sendable {
    case notSignedIn(String)
    case expired(String)
    case unauthorized(String)
    case rateLimited(retryAfter: Date?)
    case blockedByCloudflare
    case http(status: Int, body: String?)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case let .notSignedIn(hint): "Not signed in. \(hint)"
        case let .expired(hint): "Login expired. \(hint)"
        case let .unauthorized(hint): "Unauthorized. \(hint)"
        case let .rateLimited(retryAfter):
            if let retryAfter {
                "Rate limited by the provider until \(retryAfter.formatted(date: .omitted, time: .shortened))."
            } else {
                "Rate limited by the provider. Will retry later."
            }
        case .blockedByCloudflare: "The provider's bot protection blocked the request. Sign in again."
        case let .http(status, body):
            if let body, !body.isEmpty { "HTTP \(status): \(body.prefix(200))" } else { "HTTP \(status)" }
        case let .invalidResponse(detail): "Unexpected response: \(detail)"
        }
    }
}
