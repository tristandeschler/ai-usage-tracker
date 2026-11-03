import SwiftUI
import UsageKit

@main
struct TokenTrackerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environment(model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(model)
        }

        WindowGroup("Sign In", id: WebSignInView.windowID, for: WebSignInView.Target.self) { $target in
            if let target {
                WebSignInView(target: target)
                    .environment(model)
            }
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 520, height: 720)
    }
}

extension Notification.Name {
    static let showSettings = Notification.Name("TokenTrackerShowSettings")
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let hasLaunchedKey = "hasLaunched"

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A menu bar app has no window, so show Settings on first launch to make it obvious it started.
        guard !UserDefaults.standard.bool(forKey: Self.hasLaunchedKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.hasLaunchedKey)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NotificationCenter.default.post(name: .showSettings, object: nil)
        }
    }

    /// Opening the app again (Finder, Spotlight, Launchpad) while it runs shows Settings instead of nothing.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        NotificationCenter.default.post(name: .showSettings, object: nil)
        return false
    }
}

struct MenuBarLabel: View {
    let model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let snapshot = model.menuBarSnapshot
        let percent = snapshot?.peakPercent
        HStack(spacing: 3) {
            Image(systemName: Self.symbol(for: percent, limited: snapshot?.isLimited == true))
            if let percent {
                Text("\(Int(percent.rounded()))%")
                    .monospacedDigit()
            }
        }
        // The label is the only view that always exists, so it handles requests to show Settings.
        .onReceive(NotificationCenter.default.publisher(for: .showSettings)) { _ in
            NSApp.activate()
            openSettings()
        }
    }

    static func symbol(for percent: Double?, limited: Bool) -> String {
        if limited { return "gauge.with.dots.needle.100percent" }
        switch percent ?? 0 {
        case 80...: return "gauge.with.dots.needle.67percent"
        case 40...: return "gauge.with.dots.needle.50percent"
        default: return "gauge.with.dots.needle.33percent"
        }
    }
}
