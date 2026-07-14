import SwiftUI
import TokenBarCore

/// Liquid Glass card surface on macOS 26+, material fallback below — the
/// glass lives on the cards themselves (the Control Center look), not on a
/// backdrop hidden behind opaque fills.
struct GlassCardBackground: ViewModifier {
    var cornerRadius: CGFloat = 10

    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            // .clear glass lets the wallpaper breathe through the cards
            // themselves (.regular reads as a dense dark slab when cards
            // fill the whole scroll area). The tint follows the appearance:
            // smoked glass in dark mode (a plain white tint washed the dark
            // theme out), a faint white lift in light mode — the Control
            // Center pebble look in both.
            // Smoke layer drawn over the glass (Glass.tint barely moves the
            // needle on .clear): dark mode gets a deterministic dark scrim,
            // light mode a faint white lift.
            content
                .background(
                    colorScheme == .dark
                        ? Color.black.opacity(0.32)
                        : Color.white.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: cornerRadius))
                .glassEffect(.clear, in: .rect(cornerRadius: cornerRadius))
        } else {
            content
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        }
    }
}

extension View {
    func glassCard(cornerRadius: CGFloat = 10) -> some View {
        modifier(GlassCardBackground(cornerRadius: cornerRadius))
    }
}

/// Floating hover-tooltip chrome. On macOS 26 it's real Liquid Glass so the
/// panel picks up the same specular rim and refraction as the cards it floats
/// over — but a tooltip overlaps dense chart/row content, so unlike the cards
/// (which use see-through `.clear` glass) we hold a heavy tinted scrim between
/// the text and the glass. Legibility wins here: clear glass would let the bars
/// and axis labels underneath bleed straight through the numbers. Older systems
/// fall back to an opaque-backed `.regularMaterial` (a bare material over the
/// `.hudWindow` backdrop reads near-transparent). A drop shadow lifts it off the
/// content in both cases so it reads as a floating panel, not a smudge.
struct TooltipSurface: ViewModifier {
    var cornerRadius: CGFloat = 8

    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .background(
                    colorScheme == .dark
                        ? Color(white: 0.12).opacity(0.78)
                        : Color(white: 0.99).opacity(0.82),
                    in: RoundedRectangle(cornerRadius: cornerRadius))
                .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
                .shadow(color: .black.opacity(0.28), radius: 9, y: 3)
        } else {
            content
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(colorScheme == .dark ? Color(white: 0.15) : Color(white: 0.99))
                        .overlay(
                            RoundedRectangle(cornerRadius: cornerRadius)
                                .fill(.regularMaterial))
                )
                .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(.quaternary))
                .shadow(color: .black.opacity(0.28), radius: 9, y: 3)
        }
    }
}

extension View {
    func tooltipSurface(cornerRadius: CGFloat = 8) -> some View {
        modifier(TooltipSurface(cornerRadius: cornerRadius))
    }
}

/// Coordinate space pinned to the popover's scroll viewport. Cards report the
/// hovered cursor position in this space so the root `HoverTooltipLayer` can
/// place the tooltip relative to the visible viewport (whose bottom is the real
/// floor — content past it is clipped), not relative to the card.
enum PopoverViewport {
    static let space = "popoverViewport"
}

/// Shared dashboard-card chrome: rounded glass panel, matching the Tauri
/// dashboard's card stack.
struct DashCard<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: () -> AnyView?
    @ViewBuilder var content: () -> Content

    init(
        _ title: String, subtitle: String? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = { nil }
        self.content = content
    }

    init<T: View>(
        _ title: String, subtitle: String? = nil,
        @ViewBuilder trailing: @escaping () -> T,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = { AnyView(trailing()) }
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                trailing()
            }
            content()
        }
        .padding(12)
        .glassCard()
    }
}

/// The three-cell totals row (Total / Tokens / Best day), ported from
/// TokenUsageCard.tsx in its bare form.
struct TokenUsageRow: View {
    let stats: UsageStats

    var body: some View {
        HStack(spacing: 8) {
            cell(
                Format.usd(stats.totalCost), "Total",
                "\(Format.mmdd(stats.dateRange.start)) → \(Format.mmdd(stats.dateRange.end))")
            cell(
                Format.compactTokens(stats.totalTokens), "Tokens",
                "\(stats.activeDays) active days")
            cell(
                stats.bestDay.map { Format.usd($0.cost) } ?? "$0.00", "Best day",
                stats.bestDay.map { Format.monthDay($0.date) } ?? "—")
        }
    }

    private func cell(_ num: String, _ label: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(num)
                .font(.system(size: 15, weight: .semibold).monospacedDigit())
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(sub)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Streak summary card, ported from StreaksCard.tsx.
struct StreaksCard: View {
    let streaks: Streaks

    var body: some View {
        DashCard("Streaks") {
            HStack(spacing: 8) {
                item(streaks.longest, "Longest")
                item(streaks.current, "Current")
            }
        }
    }

    private func item(_ days: Int, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            (Text("\(days)").font(.system(size: 17, weight: .semibold).monospacedDigit())
                + Text(" days").font(.caption).foregroundStyle(.secondary))
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
