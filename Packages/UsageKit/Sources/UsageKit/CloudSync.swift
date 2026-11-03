#if canImport(CloudKit)
import CloudKit
import Foundation

/// Mirrors snapshots and alerts through the user's private iCloud database so the iOS
/// companion can show them and push limit alerts.
///
/// Credentials never leave the Mac; only usage snapshots are synced.
public actor CloudSync {
    public static let containerID = "iCloud.com.tristandeschler.TokenTracker"
    static let zoneID = CKRecordZone.ID(zoneName: "Usage")
    static let snapshotType = "AccountSnapshot"
    static let alertType = "UsageAlert"

    private let database: CKDatabase
    private var zoneReady = false

    public init(containerID: String = CloudSync.containerID) {
        database = CKContainer(identifier: containerID).privateCloudDatabase
    }

    private func ensureZone() async throws {
        guard !zoneReady else { return }
        _ = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: Self.zoneID)], deleting: [])
        zoneReady = true
    }

    private static func recordID(_ name: String) -> CKRecord.ID {
        CKRecord.ID(recordName: name, zoneID: zoneID)
    }

    // MARK: Mac → iCloud

    public func publish(_ snapshots: [AccountSnapshot], removing removed: [UUID] = []) async throws {
        try await ensureZone()
        let encoder = JSONEncoder()
        let records = try snapshots.map { snapshot in
            let record = CKRecord(recordType: Self.snapshotType, recordID: Self.recordID(snapshot.id.uuidString))
            record["payload"] = try encoder.encode(snapshot)
            record["updatedAt"] = snapshot.fetchedAt
            return record
        }
        _ = try await database.modifyRecords(
            saving: records,
            deleting: removed.map { Self.recordID($0.uuidString) },
            savePolicy: .allKeys,
            atomically: false
        )
    }

    public func publish(_ alert: UsageAlert) async throws {
        try await ensureZone()
        let record = CKRecord(recordType: Self.alertType, recordID: Self.recordID("alert-\(UUID().uuidString)"))
        record["title"] = alert.title
        record["body"] = alert.body
        record["createdAt"] = Date()
        _ = try await database.modifyRecords(saving: [record], deleting: [])
    }

    /// Alert records only exist to trigger a push; delete old ones so the zone stays small.
    public func pruneAlerts(olderThan age: TimeInterval = 86_400) async throws {
        let records = try await allRecords()
        let cutoff = Date().addingTimeInterval(-age)
        let stale = records
            .filter { $0.recordType == Self.alertType && (($0["createdAt"] as? Date) ?? .distantPast) < cutoff }
            .map(\.recordID)
        guard !stale.isEmpty else { return }
        _ = try await database.modifyRecords(saving: [], deleting: stale)
    }

    // MARK: iCloud → iOS

    public func fetchSnapshots() async throws -> [AccountSnapshot] {
        let decoder = JSONDecoder()
        return try await allRecords()
            .filter { $0.recordType == Self.snapshotType }
            .compactMap { ($0["payload"] as? Data).flatMap { try? decoder.decode(AccountSnapshot.self, from: $0) } }
    }

    /// Registers a visible push for every new alert and a silent push when snapshots change.
    public func subscribe() async throws {
        try await ensureZone()

        let alerts = CKQuerySubscription(
            recordType: Self.alertType,
            predicate: NSPredicate(value: true),
            subscriptionID: "usage-alerts",
            options: [.firesOnRecordCreation]
        )
        alerts.zoneID = Self.zoneID
        let info = CKSubscription.NotificationInfo()
        // An unknown localization key is used as the format string itself.
        info.titleLocalizationKey = "%1$@"
        info.titleLocalizationArgs = ["title"]
        info.alertLocalizationKey = "%1$@"
        info.alertLocalizationArgs = ["body"]
        info.soundName = "default"
        alerts.notificationInfo = info

        let changes = CKRecordZoneSubscription(zoneID: Self.zoneID, subscriptionID: "usage-changes")
        let silent = CKSubscription.NotificationInfo()
        silent.shouldSendContentAvailable = true
        changes.notificationInfo = silent

        _ = try await database.modifySubscriptions(saving: [alerts, changes], deleting: [])
    }

    private func allRecords() async throws -> [CKRecord] {
        try await ensureZone()
        var records: [CKRecord] = []
        var token: CKServerChangeToken?
        var more = true
        while more {
            let changes = try await database.recordZoneChanges(inZoneWith: Self.zoneID, since: token)
            for (_, result) in changes.modificationResultsByID {
                if case let .success(modification) = result { records.append(modification.record) }
            }
            token = changes.changeToken
            more = changes.moreComing
        }
        return records
    }
}
#endif
