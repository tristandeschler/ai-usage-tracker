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

enum TokenFormat {
    /// "33.1M", "1.4B", "812".
    static func short(_ count: Int) -> String {
        count.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
    }

    static func breakdown(_ counts: TokenCounts, title: String) -> String {
        """
        \(title)
        Input: \(short(counts.input))
        Output: \(short(counts.output))
        Cache reads: \(short(counts.cacheRead))
        Cache writes: \(short(counts.cacheWrite))
        """
    }
}

/// Today and the last 7 days of tokens from this Mac's CLI logs, with a per-day bar chart.
struct TokenSection: View {
    let tokens: TokenTotals
    let accent: Color
    let now: Date
    @State private var hoveredDay: Int?

    private struct Day: Identifiable {
        let id: Int
        let date: Date
        let total: Int
    }

    private var days: [Day] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let daily = tokens.daily ?? []
        return daily.enumerated().map { index, total in
            let date = calendar.date(byAdding: .day, value: index - (daily.count - 1), to: today) ?? today
            return Day(id: index, date: date, total: total)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tokens on this Mac")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            if tokens.lastSevenDays.total == 0 {
                Text("Nothing logged in the last 7 days")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                tiles
            }
        }
    }

    private var tiles: some View {
            HStack(alignment: .top, spacing: 16) {
                stat("Today", value: tokens.today.total, detail: comparison)
                    .help(TokenFormat.breakdown(tokens.today, title: "Today"))
                VStack(alignment: .leading, spacing: 4) {
                    stat(hoveredLabel ?? "Last 7 days", value: hoveredValue ?? tokens.lastSevenDays.total, detail: nil)
                        .help(TokenFormat.breakdown(tokens.lastSevenDays, title: "Last 7 days"))
                    if !days.isEmpty { chart }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
    }

    private func stat(_ label: String, value: Int, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(TokenFormat.short(value))
                .font(.title3.weight(.semibold))
                .contentTransition(.numericText())
            if let detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 70, alignment: .leading)
    }

    /// Today against the six days before it.
    private var comparison: String? {
        guard let average = tokens.previousDailyAverage else { return nil }
        let ratio = Double(tokens.today.total) / average
        switch ratio {
        case ..<0.85: return "below your usual"
        case ...1.15: return "about your usual"
        default: return "\(ratio.formatted(.number.precision(.fractionLength(1))))× your usual"
        }
    }

    private var hoveredLabel: String? {
        guard let hoveredDay, days.indices.contains(hoveredDay) else { return nil }
        let day = days[hoveredDay]
        return hoveredDay == days.count - 1 ? "Today" : day.date.formatted(.dateTime.weekday(.wide))
    }

    private var hoveredValue: Int? {
        guard let hoveredDay, days.indices.contains(hoveredDay) else { return nil }
        return days[hoveredDay].total
    }

    /// One bar per day; today in the account's color, earlier days recessive.
    private var chart: some View {
        Chart(days) { day in
            BarMark(
                x: .value("Day", String(day.id)),
                y: .value("Tokens", day.total),
                width: .ratio(0.7)
            )
            .cornerRadius(2)
            .foregroundStyle(day.id == days.count - 1 ? accent : Color.gray.opacity(0.45))
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
                        // Days are categories ("0"…"6"), so the hovered column maps straight to an index.
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
        .accessibilityLabel("Tokens per day for the last 7 days")
        .accessibilityValue(days.map { "\($0.date.formatted(.dateTime.weekday(.wide))) \(TokenFormat.short($0.total))" }.joined(separator: ", "))
    }
}

/// How an account's weekly usage splits across Claude apps, as a thin stacked bar plus a legend.
struct AppShareBar: View {
    let shares: [AppShare]

    /// Categorical slots in a fixed order, keyed by app so a color always means the same app.
    /// Validated for colorblind separation on light and dark surfaces.
    private static let slots: [Color] = [
        .adaptive(light: 0x2A78D6, dark: 0x3987E5), // blue
        .adaptive(light: 0xEB6834, dark: 0xD95926), // orange
        .adaptive(light: 0x1BAF7A, dark: 0x199E70), // aqua
        .adaptive(light: 0xEDA100, dark: 0xC98500), // yellow
    ]
    private static let knownApps = ["Claude Code", "Chats", "Cowork", "Other"]

    private func color(for share: AppShare) -> Color {
        let index = Self.knownApps.firstIndex(of: share.name) ?? 3
        return Self.slots[index]
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
