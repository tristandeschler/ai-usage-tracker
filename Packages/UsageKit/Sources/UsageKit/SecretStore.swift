import Foundation
import Security

public protocol SecretStore: Sendable {
    func read(_ key: String) throws -> String?
    func write(_ value: String, for key: String) throws
    func delete(_ key: String) throws
}

/// Stores secrets in the data protection keychain, readable only by this app, never synced or
/// carried to another Mac through backups or migration, and unreadable until the Mac has been
/// unlocked once after starting up.
///
/// That keychain needs the app to be signed with a team. Unsigned builds fall back to the
/// login keychain, and secrets saved there by older versions move over on first read.
public struct KeychainSecretStore: SecretStore {
    public let service: String

    public init(service: String = "\(Bundle.main.bundleIdentifier ?? "TokenTracker").credentials") {
        self.service = service
    }

    private func query(_ key: String, dataProtection: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        if dataProtection { query[kSecUseDataProtectionKeychain as String] = true }
        return query
    }

    public func read(_ key: String) throws -> String? {
        switch try copy(key, dataProtection: true) {
        case let .found(value):
            return value
        case .notFound:
            // Migrate anything an older version stored in the login keychain.
            guard case let .found(value) = try copy(key, dataProtection: false) else { return nil }
            if (try? add(value, for: key, dataProtection: true)) != nil {
                SecItemDelete(query(key, dataProtection: false) as CFDictionary)
            }
            return value
        case .unavailable:
            guard case let .found(value) = try copy(key, dataProtection: false) else { return nil }
            return value
        }
    }

    public func write(_ value: String, for key: String) throws {
        do {
            try upsert(value, for: key, dataProtection: true)
        } catch let error as KeychainError where error.status == errSecMissingEntitlement {
            try upsert(value, for: key, dataProtection: false)
        }
    }

    public func delete(_ key: String) throws {
        for dataProtection in [true, false] {
            let status = SecItemDelete(query(key, dataProtection: dataProtection) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound || status == errSecMissingEntitlement else {
                throw KeychainError(status: status)
            }
        }
    }

    private enum Lookup { case found(String), notFound, unavailable }

    private func copy(_ key: String, dataProtection: Bool) throws -> Lookup {
        var q = query(key, dataProtection: dataProtection)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else { return .notFound }
            return .found(value)
        case errSecItemNotFound: return .notFound
        case errSecMissingEntitlement where dataProtection: return .unavailable
        default: throw KeychainError(status: status)
        }
    }

    private func upsert(_ value: String, for key: String, dataProtection: Bool) throws {
        let status = SecItemUpdate(
            query(key, dataProtection: dataProtection) as CFDictionary,
            [kSecValueData as String: Data(value.utf8)] as CFDictionary
        )
        if status == errSecItemNotFound {
            try add(value, for: key, dataProtection: dataProtection)
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }

    private func add(_ value: String, for key: String, dataProtection: Bool) throws {
        var q = query(key, dataProtection: dataProtection)
        q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }
}

public struct KeychainError: LocalizedError {
    public let status: OSStatus
    public var errorDescription: String? {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
        return "Keychain error \(status): \(message)"
    }
}

/// In-memory store for tests and previews.
public final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private var values: [String: String]
    private let lock = NSLock()

    public init(_ values: [String: String] = [:]) { self.values = values }

    public func read(_ key: String) throws -> String? { lock.withLock { values[key] } }
    public func write(_ value: String, for key: String) throws { lock.withLock { values[key] = value } }
    public func delete(_ key: String) throws { _ = lock.withLock { values.removeValue(forKey: key) } }
}
