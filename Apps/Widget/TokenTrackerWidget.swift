import SwiftUI
import UsageKit
import WidgetKit

@main
struct TokenTrackerWidgets: WidgetBundle {
    var body: some Widget {
        UsageWidget()
    }
}

struct UsageEntry: TimelineEntry {
    let date: Date
    let shared: SharedSnapshots?
}

struct UsageProvider: TimelineProvider {
    func placeholder(in context: Context) -> UsageEntry {
        UsageEntry(date: .now, shared: .sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        completion(UsageEntry(date: .now, shared: context.isPreview ? .sample : SharedSnapshots.load() ?? .sample))
    }

    /// The app reloads widgets after every refresh; the timeline only keeps reset countdowns fresh.
    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        let shared = SharedSnapshots.load()
        let entries = (0..<4).map { step in
            UsageEntry(date: Date().addingTimeInterval(Double(step) * 15 * 60), shared: shared)
        }
        completion(Timeline(entries: entries, policy: .atEnd))
    }
}

struct UsageWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TokenTrackerUsage", provider: UsageProvider()) { entry in
            UsageWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Usage")
        .description("How much of your Claude and ChatGPT limits you've used.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct UsageWidgetView: View {
    let entry: UsageEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let accounts = entry.shared?.ordered, !accounts.isEmpty {
            switch family {
            case .systemSmall: SmallUsageView(snapshot: accounts[0], now: entry.date)
            case .systemLarge: AccountList(snapshots: Array(accounts.prefix(5)), now: entry.date)
            default: AccountList(snapshots: Array(accounts.prefix(3)), now: entry.date)
            }
        } else {
            VStack(spacing: 6) {
                Image(systemName: "gauge.with.dots.needle.33percent").font(.title2)
                Text("Open Token Tracker to add an account").font(.caption).multilineTextAlignment(.center)
            }
            .foregroundStyle(.secondary)
        }
    }
}

/// One account: its logo, name, and the limit closest to running out.
struct SmallUsageView: View {
    let snapshot: AccountSnapshot
    let now: Date

    private var tightest: UsageWindow? { snapshot.windows.max { $0.usedPercent < $1.usedPercent } }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ProviderBadge(snapshot.provider, size: 16)
                Text(snapshot.accountName).font(.caption.weight(.semibold)).lineLimit(1)
            }
            Spacer(minLength: 0)
            if let window = tightest {
                Text("\(Int(window.usedPercent.rounded()))%")
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .foregroundStyle(window.isExhausted ? .red : .primary)
                    .contentTransition(.numericText())
                UsageBar(percent: window.usedPercent)
                Text(caption(for: window))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if let spend = snapshot.spend {
                Text(spend.lastSevenDays.formatted(.currency(code: "USD")))
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                Text("API spend, last 7 days").font(.caption2).foregroundStyle(.secondary)
            } else {
                Text(snapshot.error ?? "No limits to show").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func caption(for window: UsageWindow) -> String {
        guard let resetsAt = window.resetsAt else { return window.label }
        return "\(window.label) · \(UsageStyle.countdown(to: resetsAt, now: now))"
    }
}

/// Several accounts, each with its tightest limit as a bar.
struct AccountList: View {
    let snapshots: [AccountSnapshot]
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(snapshots) { snapshot in
                let window = snapshot.windows.max { $0.usedPercent < $1.usedPercent }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        ProviderBadge(snapshot.provider, size: 14)
                        Text(snapshot.accountName).font(.caption.weight(.semibold)).lineLimit(1)
                        Spacer(minLength: 4)
                        if let window {
                            Text("\(Int(window.usedPercent.rounded()))%")
                                .font(.caption.weight(.semibold))
                                .monospacedDigit()
                                .foregroundStyle(window.isExhausted ? .red : .primary)
                        } else if let spend = snapshot.spend {
                            Text(spend.today.formatted(.currency(code: "USD")) + " today")
                                .font(.caption.weight(.semibold))
                                .monospacedDigit()
                        }
                    }
                    if let window {
                        UsageBar(percent: window.usedPercent)
                        if let resetsAt = window.resetsAt {
                            Text("\(window.label) · resets in \(UsageStyle.countdown(to: resetsAt, now: now))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension SharedSnapshots {
    /// Shown in the widget gallery before the app has written anything.
    static let sample = SharedSnapshots(
        snapshots: [
            AccountSnapshot(id: UUID(), accountName: "Personal", provider: .anthropic, plan: "Max",
                            windows: [UsageWindow(id: "weekly", label: "Weekly", kind: .weekly, usedPercent: 46, resetsAt: Date().addingTimeInterval(100_000))]),
            AccountSnapshot(id: UUID(), accountName: "Work", provider: .openai, plan: "Pro",
                            windows: [UsageWindow(id: "session", label: "5-hour session", kind: .session, usedPercent: 82, resetsAt: Date().addingTimeInterval(5_000))]),
        ],
        featuredAccountID: nil
    )
}
