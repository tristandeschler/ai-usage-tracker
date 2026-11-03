import Foundation

/// What the app hands to its widgets: usage numbers only, never credentials.
public struct SharedSnapshots: Codable, Sendable {
    public var snapshots: [AccountSnapshot]
    /// The account the menu bar is showing, so widgets can lead with it.
    public var featuredAccountID: UUID?
    public var updatedAt: Date

    public init(snapshots: [AccountSnapshot], featuredAccountID: UUID?, updatedAt: Date = Date()) {
        self.snapshots = snapshots
        self.featuredAccountID = featuredAccountID
        self.updatedAt = updatedAt
    }

    /// The app group shared by the app and its widgets, from the `TTAppGroup` Info.plist key.
    public static var appGroup: String? {
        Bundle.main.object(forInfoDictionaryKey: "TTAppGroup") as? String
    }

    private static var fileURL: URL? {
        guard let group = appGroup,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
        else { return nil }
        return container.appendingPathComponent("snapshots.json")
    }

    public func save() throws {
        guard let url = Self.fileURL else { return }
        try JSONEncoder().encode(self).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    public static func load() -> SharedSnapshots? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SharedSnapshots.self, from: data)
    }

    /// Featured account first, then the rest in the app's order.
    public var ordered: [AccountSnapshot] {
        guard let featuredAccountID, let index = snapshots.firstIndex(where: { $0.id == featuredAccountID }) else { return snapshots }
        var list = snapshots
        list.insert(list.remove(at: index), at: 0)
        return list
    }
}
