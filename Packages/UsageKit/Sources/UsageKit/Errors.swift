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
        case let .notSignedIn(hint): "Signed out. \(hint)"
        case let .expired(hint): "Login expired. \(hint)"
        case let .unauthorized(hint): "The login was rejected. \(hint)"
        case let .rateLimited(retryAfter):
            if let retryAfter {
                "Checked too often. Trying again at \(retryAfter.formatted(date: .omitted, time: .shortened))."
            } else {
                "Checked too often. Trying again in a bit."
            }
        case .blockedByCloudflare: "Blocked by the site's bot check. Sign in again."
        case let .http(status, body):
            if let body, !body.isEmpty {
                "Something went wrong on their end (HTTP \(status)): \(body.prefix(200))"
            } else {
                "Something went wrong on their end (HTTP \(status))."
            }
        case let .invalidResponse(detail): "Got a response the app doesn't understand (\(detail))."
        }
    }
}
