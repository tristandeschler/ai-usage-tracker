import SwiftUI
import UsageKit

@main
struct TokenTrackerApp: App {
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

struct MenuBarLabel: View {
    let model: AppModel

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
