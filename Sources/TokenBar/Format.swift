import Foundation
import TokenBarCore

/// Small display formatters shared by the tray title and the popover.
enum Format {
    /// Compact token count: 999 → "999", 12_345 → "12.3K", 1_234_567 → "1.2M".
    static func compactTokens(_ count: Int64) -> String {
        let value = Double(count)
        let scaled: Double
        let suffix: String
        switch value {
        case 1_000_000_000...:
            (scaled, suffix) = (value / 1_000_000_000, "B")
        case 1_000_000...:
            (scaled, suffix) = (value / 1_000_000, "M")
        case 1_000...:
            (scaled, suffix) = (value / 1_000, "K")
        default:
            return String(count)
        }
        var text = scaled >= 100 ? String(format: "%.0f", scaled) : String(format: "%.1f", scaled)
        if text.hasSuffix(".0") { text.removeLast(2) }
        return text + suffix
    }

    static func usd(_ amount: Double) -> String {
        String(format: "$%.2f", amount)
    }

    /// Today's contribution-graph day key. tokscale-core buckets days in the
    /// local timezone as `%Y-%m-%d`, so we must match that exactly.
    static func todayKey(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: now)
    }

    /// Total tokens recorded today in `graph` (0 when today has no entry).
    static func todayTokens(in graph: UsagePayload) -> Int64 {
        let today = todayKey()
        // Contributions are date-sorted; today, if present, is at the tail.
        return graph.contributions.last(where: { $0.date == today })?.totals.tokens ?? 0
    }

    private static let monthsShort = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun",
        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    ]

    /// "2026-06-10" → "Jun 10".
    static func monthDay(_ iso: String) -> String {
        let parts = iso.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...12).contains(parts[1]) else { return iso }
        return "\(monthsShort[parts[1] - 1]) \(parts[2])"
    }

    /// "2026-06-10" → "06/10".
    static func mmdd(_ iso: String) -> String {
        let parts = iso.split(separator: "-")
        guard parts.count == 3 else { return iso }
        return "\(parts[1])/\(parts[2])"
    }

    /// Exact token count with thousands separators ("1,234,567").
    static func exactTokens(_ count: Int64) -> String {
        count.formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US")))
    }
}
