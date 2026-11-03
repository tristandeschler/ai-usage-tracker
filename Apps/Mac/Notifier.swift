import Foundation
import UserNotifications
import UsageKit

final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()

    override init() {
        super.init()
        center.delegate = self
    }

    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error { NSLog("Notification authorization failed: \(error)") }
        }
    }

    func post(_ alert: UsageAlert) {
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        if case let .crossed(threshold) = alert.kind, threshold >= 100 {
            content.sound = .default
            content.interruptionLevel = .timeSensitive
        }
        // One live notification per account window; a newer one replaces the older.
        let id = "\(alert.accountID.uuidString)|\(alert.window.id)"
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    func postUpdate(version: String) {
        let content = UNMutableNotificationContent()
        content.title = "Token Tracker \(version) is out"
        content.body = "Open the menu and click Update to install it."
        center.add(UNNotificationRequest(identifier: "update-\(version)", content: content, trigger: nil))
    }

    // Show banners even though a menu bar app is technically always "in the foreground".
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
