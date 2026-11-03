import Charts
import SwiftUI

extension Color {
    /// A color with separate light- and dark-mode values.
    static func adaptive(light: UInt32, dark: UInt32) -> Color {
        #if os(macOS)
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
        #else
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
        #endif
    }
}

#if os(macOS)
private extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
#else
private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
#endif

/// Brand colors for charts. Anthropic's clay, sky and fig, and OpenAI's green, each stepped
/// for light and dark and checked for colorblind separation.
enum BrandPalette {
    static func accent(_ provider: ProviderKind) -> Color {
        switch provider {
        case .anthropic: .adaptive(light: 0xD97757, dark: 0xCF6A48)  // clay
        case .openai: .adaptive(light: 0x10A37F, dark: 0x19B98F)     // OpenAI green
        }
    }

    /// Recessive bars and "Other": Anthropic's cloud gray, or OpenAI's neutral gray.
    static func muted(_ provider: ProviderKind) -> Color {
        switch provider {
        case .anthropic: .adaptive(light: 0xBFBFBA, dark: 0x666663)
        case .openai: .adaptive(light: 0xC5C5D2, dark: 0x565869)
        }
    }

    /// Claude apps in a fixed order, so a color always means the same app.
    static let claudeApps: [String: Color] = [
        "Claude Code": .adaptive(light: 0xD97757, dark: 0xCF6A48), // clay
        "Chats": .adaptive(light: 0x4A86C5, dark: 0x5A93D0),       // sky
        "Cowork": .adaptive(light: 0xC25A85, dark: 0xC9628D),      // fig
    ]
}

enum UsageFormat {
    /// "33.1M", "1.4B", "812".
    static func tokens(_ count: Int) -> String {
        count.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
    }

    /// "$12.40", "$1,284".
    static func dollars(_ amount: Double) -> String {
        amount.formatted(.currency(code: "USD").precision(.fractionLength(amount >= 1_000 ? 0 : 2)))
    }

    static func breakdown(_ counts: TokenCounts, title: String) -> String {
        """
        \(title)
        Input: \(tokens(counts.input))
        Output: \(tokens(counts.output))
        Cache reads: \(tokens(counts.cacheRead))
        Cache writes: \(tokens(counts.cacheWrite))
        """
    }
}

/// An API account's spend and tokens for today and the last 7 days, with daily spend as bars.
struct APIUsageSection: View {
    let spend: SpendTotals?
    let tokens: TokenTotals?
    let provider: ProviderKind
    let now: Date
    @State private var hoveredDay: Int?

    private struct Day: Identifiable {
        let id: Int
        let date: Date
        let amount: Double
    }

    private var days: [Day] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let today = calendar.startOfDay(for: now)
        let daily = spend?.daily ?? []
        return daily.enumerated().map { index, amount in
            let date = calendar.date(byAdding: .day, value: index - (daily.count - 1), to: today) ?? today
            return Day(id: index, date: date, amount: amount)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            stat("Today", spend: spend?.today, tokens: tokens?.today)
            VStack(alignment: .leading, spacing: 4) {
                if let hovered = hoveredDay.flatMap({ index in days.indices.contains(index) ? days[index] : nil }) {
                    stat(hovered.id == days.count - 1 ? "Today" : hovered.date.formatted(Date.FormatStyle(timeZone: TimeZone(identifier: "UTC")!).weekday(.wide)),
                         spend: hovered.amount, tokens: nil)
                } else {
                    stat("Last 7 days", spend: spend?.lastSevenDays, tokens: tokens?.lastSevenDays)
                }
                if days.contains(where: { $0.amount > 0 }) { chart }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func stat(_ label: String, spend: Double?, tokens: TokenCounts?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(spend.map(UsageFormat.dollars) ?? "–")
                .font(.title3.weight(.semibold))
                .contentTransition(.numericText())
            if let tokens {
                Text("\(UsageFormat.tokens(tokens.total)) tokens")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help(UsageFormat.breakdown(tokens, title: label))
            }
        }
        .frame(minWidth: 80, alignment: .leading)
    }

    /// One bar per UTC day; today in the brand color, earlier days recessive.
    private var chart: some View {
        Chart(days) { day in
            BarMark(
                // Days are categories so the bars get a width.
                x: .value("Day", String(day.id)),
                y: .value("Spend", day.amount),
                width: .ratio(0.7)
            )
            .cornerRadius(2)
            .foregroundStyle(day.id == days.count - 1 ? BrandPalette.accent(provider) : BrandPalette.muted(provider))
            .opacity(hoveredDay == nil || hoveredDay == day.id ? 1 : 0.5)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartOverlay { proxy in
            Rectangle()
                .fill(.clear)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case let .active(location):
                        if let label: String = proxy.value(atX: location.x), let index = Int(label) {
                            hoveredDay = index
                        }
                    case .ended:
                        hoveredDay = nil
                    }
                }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 26)
        .accessibilityLabel("Spend per day for the last 7 days")
        .accessibilityValue(days.map { "\($0.date.formatted(.dateTime.weekday(.wide))) \(UsageFormat.dollars($0.amount))" }.joined(separator: ", "))
    }
}

/// How an account's weekly usage splits across Claude apps, as a thin stacked bar plus a legend.
struct AppShareBar: View {
    let shares: [AppShare]

    private func color(for share: AppShare) -> Color {
        BrandPalette.claudeApps[share.name] ?? BrandPalette.muted(.anthropic)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("This week by app")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            GeometryReader { proxy in
                let total = max(shares.map(\.percent).reduce(0, +), 1)
                let gaps = CGFloat(max(shares.count - 1, 0)) * 2
                HStack(spacing: 2) {
                    ForEach(shares, id: \.name) { share in
                        Capsule()
                            .fill(color(for: share))
                            .frame(width: max(2, (proxy.size.width - gaps) * share.percent / total))
                            .help("\(share.name): \(Int(share.percent.rounded()))% of this week's usage")
                    }
                }
            }
            .frame(height: 6)

            HStack(spacing: 10) {
                ForEach(shares, id: \.name) { share in
                    HStack(spacing: 4) {
                        Circle().fill(color(for: share)).frame(width: 6, height: 6)
                        Text("\(share.name) \(Int(share.percent.rounded()))%")
                    }
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
