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

/// Brand colors for charts: Anthropic's clay and cloud gray, OpenAI's green and gray, each
/// stepped for light and dark.
enum BrandPalette {
    static func accent(_ provider: ProviderKind) -> Color {
        switch provider {
        case .anthropic: .adaptive(light: 0xD97757, dark: 0xCF6A48)  // clay
        case .openai: .adaptive(light: 0x10A37F, dark: 0x19B98F)     // OpenAI green
        }
    }

    /// Swift Charts doesn't resolve dynamic colors, so charts pick the value for the current scheme.
    static func chartColor(accent: Bool, _ provider: ProviderKind, _ scheme: ColorScheme) -> Color {
        let dark = scheme == .dark
        let hex: UInt32 = switch (provider, accent) {
        case (.anthropic, true): dark ? 0xCF6A48 : 0xD97757
        case (.openai, true): dark ? 0x19B98F : 0x10A37F
        case (.anthropic, false): dark ? 0x7A7A76 : 0x91918D
        case (.openai, false): dark ? 0x6E6E80 : 0x8E8EA0
        }
        return Color(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }

    /// Recessive bars and tracks: Anthropic's cloud gray, or OpenAI's neutral gray.
    static func muted(_ provider: ProviderKind) -> Color {
        switch provider {
        case .anthropic: .adaptive(light: 0x91918D, dark: 0x7A7A76)
        case .openai: .adaptive(light: 0x8E8EA0, dark: 0x6E6E80)
        }
    }
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
    @Environment(\.colorScheme) private var colorScheme

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
            .foregroundStyle(BrandPalette.chartColor(accent: day.id == days.count - 1, provider, colorScheme))
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

/// Usage per API key over the last 7 days, biggest first: spend where the provider reports it
/// per key (Anthropic), tokens otherwise.
struct APIKeyBreakdown: View {
    let keys: [APIKeyUsage]
    let provider: ProviderKind
    @State private var showAll = false

    private static let collapsedCount = 5

    private var visible: [APIKeyUsage] {
        showAll || keys.count <= Self.collapsedCount + 1 ? keys : Array(keys.prefix(Self.collapsedCount))
    }

    var body: some View {
        let bySpend = keys.contains { $0.spendLastSevenDays != nil }
        let value: (APIKeyUsage) -> Double = { bySpend ? $0.spendLastSevenDays ?? 0 : Double($0.lastSevenDays) }
        let busiest = max(keys.map(value).max() ?? 1, .leastNonzeroMagnitude)
        VStack(alignment: .leading, spacing: 7) {
            Text(bySpend ? "By API key · last 7 days" : "Tokens by API key · last 7 days")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            ForEach(visible) { key in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(key.name)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        if let spend = key.spendLastSevenDays {
                            Text(UsageFormat.tokens(key.lastSevenDays))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                            Text(UsageFormat.dollars(spend))
                                .font(.caption.weight(.medium))
                                .monospacedDigit()
                        } else {
                            Text(UsageFormat.tokens(key.lastSevenDays))
                                .font(.caption.weight(.medium))
                                .monospacedDigit()
                        }
                    }
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(BrandPalette.muted(provider).opacity(0.35))
                            Capsule()
                                .fill(BrandPalette.accent(provider))
                                .frame(width: max(4, proxy.size.width * value(key) / busiest))
                        }
                    }
                    .frame(height: 4)
                }
                .help("\(key.name): \(UsageFormat.tokens(key.today)) tokens today, \(UsageFormat.tokens(key.lastSevenDays)) in the last 7 days" + (key.spendLastSevenDays.map { ", \(UsageFormat.dollars($0)) spent (can lag up to a day)" } ?? ""))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(key.name), \(UsageFormat.tokens(key.lastSevenDays)) tokens in the last 7 days")
            }

            if keys.count > visible.count || showAll {
                Button(showAll ? "Show fewer" : "Show \(keys.count - visible.count) more keys") {
                    withAnimation(.snappy) { showAll.toggle() }
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
        }
    }
}
