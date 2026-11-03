import SwiftUI
import UIKit
import UserNotifications
import UsageKit

@main
struct TokenTrackerIOSApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = CompanionModel.shared

    var body: some Scene {
        WindowGroup {
            DashboardView()
                .environment(model)
        }
    }
}

@MainActor
@Observable
final class CompanionModel {
    static let shared = CompanionModel()

    private(set) var snapshots: [AccountSnapshot] = []
    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var lastSync: Date?

    private let cloud = CloudSync()
    private static let cacheKey = "snapshots"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.cacheKey),
           let cached = try? JSONDecoder().decode([AccountSnapshot].self, from: data) {
            snapshots = cached
        }
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let fetched = try await cloud.fetchSnapshots()
            // Limited accounts first, then by name.
            snapshots = fetched.sorted {
                if $0.isLimited != $1.isLimited { return $0.isLimited }
                return $0.accountName.localizedStandardCompare($1.accountName) == .orderedAscending
            }
            lastSync = Date()
            error = nil
            UserDefaults.standard.set(try? JSONEncoder().encode(snapshots), forKey: Self.cacheKey)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func subscribe() async {
        do {
            try await cloud.subscribe()
        } catch {
            self.error = "Couldn't register for alerts: \(error.localizedDescription)"
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        application.registerForRemoteNotifications()
        Task { await CompanionModel.shared.subscribe() }
        return true
    }

    /// Silent CloudKit push: the Mac published new snapshots.
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any]
    ) async -> UIBackgroundFetchResult {
        await CompanionModel.shared.refresh()
        return .newData
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        Task { @MainActor in await CompanionModel.shared.refresh() }
        return [.banner, .sound]
    }
}
