import SwiftUI
import TokenBarCore

/// The "Token Usage" card: trailing-30-day stacked bars with Model/Agent
/// stacking and Tokens/Price metric toggles, a wrapping legend, and a rich
/// hover tooltip. Port of UsageBarGraph2D.tsx (2D mode; the 3D toggle arrives
/// with the SceneKit graph in a later phase).
struct UsageChartCard: View {
    let payload: UsagePayload
    let stats: UsageStats
    let colors: ModelColorMap

    @AppStorage("tokenbar.chart.stackBy") private var stackByRaw = StackBy.model.rawValue
    @AppStorage("tokenbar.chart.metric") private var metricRaw = ChartMetric.tokens.rawValue
    @State private var hoverIndex: Int?

    private static let legendMax = 12
    private static let chartHeight: CGFloat = 150
    private static let gap: CGFloat = 3

    private var stackBy: StackBy { StackBy(rawValue: stackByRaw) ?? .model }
    private var metric: ChartMetric { ChartMetric(rawValue: metricRaw) ?? .tokens }

    private var bars: [DayBar] {
        DayBars.build(
            payload: payload, clientIds: stats.presentClients, stackBy: stackBy,
            colors: colors, endFallback: Format.todayKey())
    }

    var body: some View {
        let bars = self.bars
        let legend = DayBars.legend(bars: bars, metric: metric)
        DashCard(
            "Token Usage",
            subtitle: stackBy == .model ? "Stacked by model" : "Stacked by agent",
            trailing: { toggles }
        ) {
            TokenUsageRow(stats: stats)
            legendView(legend)
            chart(bars)
            HStack {
                axisLabel(bars.first?.date)
                Spacer()
                axisLabel(bars.last?.date)
            }
        }
    }

    // MARK: - Header toggles

    private var toggles: some View {
        VStack(alignment: .trailing, spacing: 4) {
            picker(selection: $stackByRaw, options: [
                (StackBy.model.rawValue, "Model"), (StackBy.agent.rawValue, "Agent"),
            ])
            picker(selection: $metricRaw, options: [
                (ChartMetric.tokens.rawValue, "Tokens"), (ChartMetric.cost.rawValue, "Price"),
            ])
        }
    }

    /// Compact two-option toggle, tighter than the native segmented picker.
    private func picker(selection: Binding<String>, options: [(String, String)]) -> some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { value, label in
                Button(label) { selection.wrappedValue = value }
                    .buttonStyle(.plain)
                    .font(.caption2.weight(selection.wrappedValue == value ? .semibold : .regular))
                    .foregroundStyle(selection.wrappedValue == value ? .primary : .secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        selection.wrappedValue == value ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: 4))
            }
        }
        .padding(1)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 5))
    }

    // MARK: - Legend

    @ViewBuilder private func legendView(_ legend: [DaySegment]) -> some View {
        let shown = Array(legend.prefix(Self.legendMax))
        let hidden = legend.count - shown.count
        if !shown.isEmpty {
            FlowLayout(hSpacing: 8, vSpacing: 3) {
                ForEach(shown, id: \.key) { item in
                    HStack(spacing: 4) {
                        Circle().fill(Color(hex: item.color)).frame(width: 6, height: 6)
                        Text(item.label).lineLimit(1)
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                if hidden > 0 {
                    Text("+\(hidden)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: - Chart

    private func chart(_ bars: [DayBar]) -> some View {
        GeometryReader { geo in
            let width = geo.size.width
            let barWidth = (width - Self.gap * CGFloat(bars.count - 1)) / CGFloat(bars.count)
            let maxValue = max(bars.map(barTotal).max() ?? 1, metric == .cost ? 0.000001 : 1)

            ZStack(alignment: .topLeading) {
                canvas(bars: bars, barWidth: barWidth, maxValue: maxValue)
                if let index = hoverIndex, bars.indices.contains(index),
                   !bars[index].isEmpty {
                    tooltip(bars[index])
                        .offset(
                            x: tooltipX(index: index, barWidth: barWidth, width: width),
                            y: 0)
                }
            }
            .onContinuousHover { phase in
                switch phase {
                case let .active(point):
                    let index = Int(point.x / (barWidth + Self.gap))
                    hoverIndex = bars.indices.contains(index) ? index : nil
                case .ended:
                    hoverIndex = nil
                }
            }
        }
        .frame(height: Self.chartHeight)
    }

    private func canvas(bars: [DayBar], barWidth: CGFloat, maxValue: Double) -> some View {
        Canvas { context, size in
            let bottom = size.height - 1
            // Axis line.
            context.fill(
                Path(CGRect(x: 0, y: bottom, width: size.width, height: 1)),
                with: .color(.secondary.opacity(0.3)))

            for (index, bar) in bars.enumerated() {
                let x = CGFloat(index) * (barWidth + Self.gap)
                let total = barTotal(bar)
                if total <= 0 {
                    context.fill(
                        Path(roundedRect: CGRect(x: x, y: bottom - 2, width: barWidth, height: 2),
                             cornerRadius: 1),
                        with: .color(.secondary.opacity(0.15)))
                    continue
                }
                let totalHeight = CGFloat(total / maxValue) * (size.height - 8)
                var y = bottom
                for segment in bar.segments {
                    let h = totalHeight * CGFloat(segValue(segment) / total)
                    guard h > 0 else { continue }
                    y -= h
                    context.fill(
                        Path(roundedRect: CGRect(x: x, y: y, width: barWidth, height: h),
                             cornerRadius: min(2, h / 2)),
                        with: .color(Color(hex: segment.color).opacity(0.86)))
                }
            }
        }
    }

    private func axisLabel(_ date: String?) -> some View {
        Text(date.map(Format.monthDay) ?? "")
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }

    private func barTotal(_ bar: DayBar) -> Double {
        metric == .cost ? bar.totalCost : Double(bar.totalTokens)
    }

    private func segValue(_ segment: DaySegment) -> Double {
        metric == .cost ? segment.cost : Double(segment.tokens)
    }

    // MARK: - Tooltip

    private static let tooltipWidth: CGFloat = 210

    private func tooltipX(index: Int, barWidth: CGFloat, width: CGFloat) -> CGFloat {
        let center = CGFloat(index) * (barWidth + Self.gap) + barWidth / 2
        return min(max(center - Self.tooltipWidth / 2, 0), width - Self.tooltipWidth)
    }

    private func tooltip(_ bar: DayBar) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Format.monthDay(bar.date))
                .font(.caption.weight(.semibold))
            HStack {
                Text("\(Format.exactTokens(bar.totalTokens)) tokens")
                Spacer()
                Text(Format.usd(bar.totalCost))
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            ForEach(
                bar.segments.sorted { $0.tokens > $1.tokens }.prefix(6), id: \.key
            ) { segment in
                HStack(spacing: 4) {
                    Circle().fill(Color(hex: segment.color)).frame(width: 5, height: 5)
                    Text(segment.label).lineLimit(1)
                    Spacer()
                    Text("\(Format.compactTokens(segment.tokens)) · \(Format.usd(segment.cost))")
                        .foregroundStyle(.secondary)
                }
                .font(.caption2)
            }
        }
        .padding(8)
        .frame(width: Self.tooltipWidth, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
        .allowsHitTesting(false)
    }
}
