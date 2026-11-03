import SwiftUI

/// Traffic-light level for a usage percentage: green, then amber from 80%, red at the limit.
public enum UsageLevel: Sendable {
    case ok
    case warning
    case limited

    public init(percent: Double) {
        switch percent {
        case 100...: self = .limited
        case 80...: self = .warning
        default: self = .ok
        }
    }
}

public enum UsageStyle {
    public static func color(for percent: Double) -> Color {
        switch UsageLevel(percent: percent) {
        case .limited: .red
        case .warning: .orange
        case .ok: .green
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

    public static let cardCornerRadius: CGFloat = 20
}

/// The provider's logo: Claude's spark in its orange, OpenAI's knot in the text color.
///
/// The logo images live in the app's asset catalog (`Apps/Shared/Brand.xcassets`).
public struct ProviderBadge: View {
    let provider: ProviderKind
    let size: CGFloat

    public init(_ provider: ProviderKind, size: CGFloat = 22) {
        self.provider = provider
        self.size = size
    }

    public var body: some View {
        Image(provider == .anthropic ? "ClaudeLogo" : "OpenAILogo", bundle: .main)
            .resizable()
            .renderingMode(.template)
            .scaledToFit()
            .foregroundStyle(provider == .anthropic ? AnyShapeStyle(UsageStyle.providerColor(.anthropic)) : AnyShapeStyle(.primary))
            .frame(width: size, height: size)
            .accessibilityLabel(provider.displayName)
    }
}

public struct UsageBar: View {
    let percent: Double

    public init(percent: Double) { self.percent = percent }

    public var body: some View {
        let color = UsageStyle.color(for: percent)
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.08))
                Capsule()
                    .fill(LinearGradient(colors: [color.opacity(0.7), color], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(proxy.size.height, proxy.size.width * min(max(percent, 0), 100) / 100))
                    .opacity(percent > 0 ? 1 : 0)
            }
        }
        .frame(height: 7)
        .accessibilityValue("\(Int(percent)) percent")
    }
}

/// Ring showing an account's highest usage.
public struct UsageRing: View {
    let percent: Double?

    public init(percent: Double?) { self.percent = percent }

    public var body: some View {
        let value = min(max(percent ?? 0, 0), 100) / 100
        let color = UsageStyle.color(for: percent ?? 0)
        ZStack {
            Circle().stroke(.primary.opacity(0.08), lineWidth: 4)
            Circle()
                .trim(from: 0, to: value)
                .stroke(color.gradient, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(percent.map { "\(Int($0.rounded()))" } ?? "–")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .frame(width: 36, height: 36)
        .accessibilityLabel("Highest usage \(Int(percent ?? 0)) percent")
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
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.label)
                    .font(.subheadline)
                Spacer()
                if let resetsAt = window.resetsAt {
                    Text("resets in \(UsageStyle.countdown(to: resetsAt, now: now))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help(resetsAt.formatted(date: .abbreviated, time: .shortened))
                }
                Text("\(Int(window.usedPercent.rounded()))%")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(window.isExhausted ? .red : .primary)
                    .frame(minWidth: 36, alignment: .trailing)
            }
            UsageBar(percent: window.usedPercent)
        }
    }
}

/// An account's usage, without a background; see `AccountGlassCard` for the styled version.
public struct AccountCard: View {
    let snapshot: AccountSnapshot
    let now: Date
    let isActive: Bool

    /// - Parameter isActive: Marks the account currently in use (its usage is going up).
    public init(snapshot: AccountSnapshot, now: Date = Date(), isActive: Bool = false) {
        self.snapshot = snapshot
        self.now = now
        self.isActive = isActive
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ProviderBadge(snapshot.provider)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(snapshot.accountName)
                            .font(.headline)
                            .lineLimit(1)
                        if isActive {
                            Label("In use", systemImage: "arrow.up.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.green)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.green.opacity(0.15), in: Capsule())
                                .help("You're using this one right now, so it's the one in the menu bar")
                        }
                    }
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if snapshot.isLimited {
                    Text(limitedText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.trailing)
                } else {
                    UsageRing(percent: snapshot.peakPercent)
                }
            }

            if let error = snapshot.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !snapshot.windows.isEmpty {
                VStack(spacing: 10) {
                    ForEach(snapshot.windows) { WindowRow(window: $0, now: now) }
                }
            } else if snapshot.error == nil {
                Text("Nothing to show yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if snapshot.tokens != nil || !(snapshot.appShares ?? []).isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    if let tokens = snapshot.tokens { TokenRow(tokens: tokens) }
                    if let shares = snapshot.appShares, !shares.isEmpty {
                        Text("This week: " + shares.map { "\($0.name) \(Int($0.percent.rounded()))%" }.joined(separator: " · "))
                            .help("How this account's weekly usage splits across Claude apps")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var subtitle: String {
        let parts = [snapshot.plan, snapshot.identity == snapshot.accountName ? nil : snapshot.identity]
            .compactMap { $0 }
        return parts.isEmpty ? snapshot.provider.displayName : parts.joined(separator: " · ")
    }

    private var limitedText: String {
        guard let until = snapshot.unblockedAt else { return "Limit reached" }
        return "Limited\nback in \(UsageStyle.countdown(to: until, now: now))"
    }
}

/// Tokens counted from this Mac's CLI logs, with the breakdown on hover.
struct TokenRow: View {
    let tokens: TokenTotals

    var body: some View {
        HStack {
            Label("Tokens", systemImage: "number")
            Spacer()
            Text("today \(Self.short(tokens.today.total)) · 7 days \(Self.short(tokens.lastSevenDays.total))")
                .monospacedDigit()
        }
        .help(Self.breakdown(tokens.lastSevenDays))
    }

    static func short(_ count: Int) -> String {
        count.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
    }

    static func breakdown(_ counts: TokenCounts) -> String {
        """
        Last 7 days on this Mac
        Input: \(short(counts.input))
        Output: \(short(counts.output))
        Cache reads: \(short(counts.cacheRead))
        Cache writes: \(short(counts.cacheWrite))
        """
    }
}

/// `AccountCard` on a Liquid Glass panel, tinted red while the account is limited.
public struct AccountGlassCard: View {
    let snapshot: AccountSnapshot
    let now: Date
    let isActive: Bool

    public init(snapshot: AccountSnapshot, now: Date = Date(), isActive: Bool = false) {
        self.snapshot = snapshot
        self.now = now
        self.isActive = isActive
    }

    public var body: some View {
        AccountCard(snapshot: snapshot, now: now, isActive: isActive)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(
                snapshot.isLimited ? .regular.tint(.red.opacity(0.2)) : .regular,
                in: .rect(cornerRadius: UsageStyle.cardCornerRadius)
            )
    }
}
