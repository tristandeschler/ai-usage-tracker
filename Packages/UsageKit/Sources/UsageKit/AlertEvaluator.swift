import Foundation

public struct UsageAlert: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// Usage rose past a threshold (100 means the limit was hit).
        case crossed(threshold: Double)
        /// A window that had hit its limit is usable again.
        case reset
    }

    public var kind: Kind
    public var accountID: UUID
    public var accountName: String
    public var provider: ProviderKind
    public var window: UsageWindow

    public var title: String {
        switch kind {
        case let .crossed(threshold) where threshold >= 100:
            "\(accountName) hit its \(window.label.lowercased()) limit"
        case let .crossed(threshold):
            "\(accountName) is at \(Int(threshold))% of its \(window.label.lowercased()) limit"
        case .reset:
            "\(accountName) is available again"
        }
    }

    public var body: String {
        switch kind {
        case .crossed:
            if let resetsAt = window.resetsAt {
                "\(provider.displayName) · \(Int(window.usedPercent.rounded()))% used · resets \(resetsAt.formatted(.relative(presentation: .named)))"
            } else {
                "\(provider.displayName) · \(Int(window.usedPercent.rounded()))% used"
            }
        case .reset:
            "\(provider.displayName) · \(window.label) is down to \(Int(window.usedPercent.rounded()))%"
        }
    }
}

/// Remembers the highest threshold already announced per account window, so each threshold
/// fires once per usage cycle.
public struct AlertState: Codable, Hashable, Sendable {
    public var notified: [String: Double] = [:]

    public init() {}

    static func key(_ accountID: UUID, _ windowID: String) -> String { "\(accountID.uuidString)|\(windowID)" }

    public mutating func forget(accountID: UUID) {
        notified = notified.filter { !$0.key.hasPrefix(accountID.uuidString) }
    }
}

public enum AlertEvaluator {
    public static let defaultThresholds: [Double] = [80, 95, 100]

    /// Compares a fresh snapshot with what was already announced and returns new alerts.
    public static func evaluate(
        _ snapshot: AccountSnapshot,
        thresholds: [Double],
        notifyOnReset: Bool,
        state: inout AlertState
    ) -> [UsageAlert] {
        // A failed fetch says nothing about usage; keep the previous state.
        guard snapshot.error == nil else { return [] }

        var alerts: [UsageAlert] = []
        for window in snapshot.windows {
            let key = AlertState.key(snapshot.id, window.id)
            let previous = state.notified[key] ?? 0
            let level = thresholds.filter { window.usedPercent >= $0 }.max() ?? 0

            func alert(_ kind: UsageAlert.Kind) -> UsageAlert {
                UsageAlert(kind: kind, accountID: snapshot.id, accountName: snapshot.accountName, provider: snapshot.provider, window: window)
            }

            if level > previous {
                alerts.append(alert(.crossed(threshold: level)))
            } else if level < previous, previous >= 100, notifyOnReset {
                alerts.append(alert(.reset))
            }
            state.notified[key] = level == 0 ? nil : level
        }

        // Claude drops the session window entirely once it has reset, so treat a vanished
        // window as back to zero.
        let present = Set(snapshot.windows.map { AlertState.key(snapshot.id, $0.id) })
        let prefix = AlertState.key(snapshot.id, "")
        for (key, previous) in state.notified where key.hasPrefix(prefix) && !present.contains(key) {
            state.notified[key] = nil
            guard previous >= 100, notifyOnReset else { continue }
            let windowID = String(key.dropFirst(prefix.count))
            let window = UsageWindow(
                id: windowID, label: windowID == "session" ? "Session (5h)" : windowID,
                kind: windowID == "session" ? .session : .other, usedPercent: 0, resetsAt: nil
            )
            alerts.append(UsageAlert(kind: .reset, accountID: snapshot.id, accountName: snapshot.accountName, provider: snapshot.provider, window: window))
        }
        return alerts
    }
}
