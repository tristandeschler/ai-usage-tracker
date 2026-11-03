import SwiftUI

public enum UsageStyle {
    public static func color(for percent: Double) -> Color {
        switch percent {
        case 100...: .red
        case 80...: .orange
        default: .green
        }
    }

    public static func providerColor(_ provider: ProviderKind) -> Color {
        switch provider {
        case .anthropic: Color(red: 0.85, green: 0.47, blue: 0.34)
        case .openai: Color(red: 0.06, green: 0.64, blue: 0.5)
        }
    }

    /// "2h 14m", "1d 6h", "12m".
    public static func countdown(to date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(now)))
        let days = seconds / 86_400, hours = seconds % 86_400 / 3_600, minutes = seconds % 3_600 / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(max(minutes, 1))m"
    }
}

public struct ProviderBadge: View {
    let provider: ProviderKind

    public init(_ provider: ProviderKind) { self.provider = provider }

    public var body: some View {
        Text(provider == .anthropic ? "A" : "O")
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: 16, height: 16)
            .background(UsageStyle.providerColor(provider), in: RoundedRectangle(cornerRadius: 4))
            .accessibilityLabel(provider.displayName)
    }
}

public struct UsageBar: View {
    let percent: Double

    public init(percent: Double) { self.percent = percent }

    public var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(UsageStyle.color(for: percent))
                    .frame(width: proxy.size.width * min(max(percent, 0), 100) / 100)
            }
        }
        .frame(height: 6)
        .accessibilityValue("\(Int(percent)) percent")
    }
}

public struct WindowRow: View {
    let window: UsageWindow
    let now: Date

    public init(window: UsageWindow, now: Date = Date()) {
        self.window = window
        self.now = now
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(window.label)
                Spacer()
                Text("\(Int(window.usedPercent.rounded()))%")
                    .monospacedDigit()
                    .fontWeight(.medium)
                    .foregroundStyle(window.isExhausted ? .red : .primary)
            }
            .font(.callout)
            UsageBar(percent: window.usedPercent)
            if let resetsAt = window.resetsAt {
                Text("Resets in \(UsageStyle.countdown(to: resetsAt, now: now)) · \(resetsAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

public struct AccountCard: View {
    let snapshot: AccountSnapshot
    let now: Date

    public init(snapshot: AccountSnapshot, now: Date = Date()) {
        self.snapshot = snapshot
        self.now = now
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ProviderBadge(snapshot.provider)
                Text(snapshot.accountName).font(.headline).lineLimit(1)
                if let plan = snapshot.plan {
                    Text(plan)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
                Spacer()
                if snapshot.isLimited {
                    Label("Limited", systemImage: "exclamationmark.octagon.fill")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.red)
                }
            }
            if let identity = snapshot.identity, identity != snapshot.accountName {
                Text(identity).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if let error = snapshot.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(snapshot.windows) { WindowRow(window: $0, now: now) }
            if snapshot.windows.isEmpty && snapshot.error == nil {
                Text("No active limits right now").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
