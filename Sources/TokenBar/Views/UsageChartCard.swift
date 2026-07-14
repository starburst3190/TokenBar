import SwiftUI
import TokenBarCore

/// The "Token Usage" card, port of UsageBarGraph2D.tsx: trailing-30-day
/// stacked bars (Model/Agent stacking, Tokens/Price metric, wrapping legend,
/// rich hover tooltip) toggling with the full-year 3D contribution grid.
struct UsageChartCard: View {
    let payload: UsagePayload
    /// Clients included in the stack (the active tab's slice).
    let clientIds: [String]
    let stats: UsageStats
    let colors: ModelColorMap
    /// Dashboard year filter; nil (all time) falls back to the current year
    /// for the 3D grid, which is inherently single-year.
    var year: String?

    @AppStorage("tokenbar.chart.stackBy") private var stackByRaw = StackBy.model.rawValue
    @AppStorage("tokenbar.chart.metric") private var metricRaw = ChartMetric.tokens.rawValue
    /// "2d" = trailing-30-day stacked bars, "3d" = full-year contribution grid.
    @AppStorage("tokenbar.chart.view") private var chartViewRaw = "2d"

    private static let legendMax = 12

    private var stackBy: StackBy { StackBy(rawValue: stackByRaw) ?? .model }
    private var metric: ChartMetric { ChartMetric(rawValue: metricRaw) ?? .tokens }

    private var bars: [DayBar] {
        // Anchor the window to the filtered stats' range (selection-derived;
        // equals meta.dateRange when nothing is hidden) so a hidden client's
        // later activity can't shift visible activity out of the chart. The
        // series spans the whole range; the chart scrolls it a window at a time.
        DayBars.build(
            payload: payload, clientIds: clientIds, stackBy: stackBy,
            colors: colors, rangeStart: stats.dateRange.start, rangeEnd: stats.dateRange.end,
            endFallback: Format.todayKey())
    }

    private var is3D: Bool { chartViewRaw == "3d" }

    var body: some View {
        let bars = self.bars
        let legend = DayBars.legend(bars: bars, metric: metric)
        DashCard(
            "Token Usage",
            subtitle: is3D
                ? "Full year"
                : (stackBy == .model ? "Stacked by model" : "Stacked by agent"),
            trailing: { toggles }
        ) {
            togglesRow
            TokenUsageRow(stats: stats)
            if is3D {
                // Year grid over the same client slice; sized to match the 2D
                // legend + chart + axis block so the card doesn't jump.
                ContributionGraph3D(
                    grid: buildGrid(
                        year: year ?? String(Format.todayKey().prefix(4)),
                        perDayMap: stats.perDayMap)
                )
                .frame(height: 196)
            } else {
                legendView(legend)
                ScrollingBarChart(bars: bars, metric: metric)
            }
        }
    }

    // MARK: - Header toggles

    /// The 2D/3D view switch rides the header; the 2D-only group/metric
    /// toggles get their own slim row below — stacked in the header they made
    /// it three rows tall and left the card top mostly whitespace, and all
    /// three don't fit beside the title without wrapping.
    private var toggles: some View {
        picker(selection: $chartViewRaw, options: [("2d", "2D"), ("3d", "3D")])
    }

    @ViewBuilder private var togglesRow: some View {
        // Stacking and bar metric are 2D-only concepts — the 3D view is the
        // year heatmap (web hides these the same way).
        if !is3D {
            HStack(spacing: 4) {
                Spacer()
                picker(selection: $stackByRaw, options: [
                    (StackBy.model.rawValue, "Model"), (StackBy.agent.rawValue, "Agent"),
                ])
                picker(selection: $metricRaw, options: [
                    (ChartMetric.tokens.rawValue, "Tokens"), (ChartMetric.cost.rawValue, "Price"),
                ])
            }
        }
    }

    /// Compact two-option toggle, tighter than the native segmented picker.
    private func picker(selection: Binding<String>, options: [(String, String)]) -> some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { value, label in
                Button(label) { selection.wrappedValue = value }
                    .buttonStyle(.plain)
                    .lineLimit(1)
                    .fixedSize()
                    .font(.caption2.weight(selection.wrappedValue == value ? .semibold : .regular))
                    .foregroundStyle(selection.wrappedValue == value ? .primary : .secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        selection.wrappedValue == value
                            ? AnyShapeStyle(Color.primary.opacity(0.16))
                            : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: 4))
            }
        }
        .padding(1)
        // Plain adaptive fill: these ride *inside* the card's glass, and
        // nesting glass effects renders as a murky dark blob.
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
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
}

/// The scrollable 2D bar strip plus its window-tracking axis labels. A
/// separate view so the scroll state lives here: a scroll tick that crosses a
/// bar slot mutates scrollSlotIndex, and if the parent card owned that state
/// each crossing would also rebuild the full DayBar series (O(history)) and
/// the legend — the scroll loop only pays for this view's body.
private struct ScrollingBarChart: View {
    let bars: [DayBar]
    let metric: ChartMetric

    @State private var hoverIndex: Int?
    @State private var hoverY: CGFloat = 0
    @State private var tooltipSize: CGSize = .zero
    /// The scroll offset published to the body, quantized to whole bar slots
    /// (index of the bar at the viewport's left edge). Every consumer — axis
    /// labels, draw culling, tooltip clamping — is slot-grained, and the snap
    /// behavior parks resting offsets on slot multiples, so publishing at bar
    /// granularity loses nothing visible while cutting the body re-eval (and
    /// Canvas re-rasterization) from every scrolled pixel to slot crossings;
    /// between crossings the scroll view just translates the drawn layer.
    @State private var scrollSlotIndex = 0
    /// Per-bar slot width, published from the scroll view's layout.
    @State private var chartSlot: CGFloat = 0
    /// The precise (per-pixel) offset, boxed OUTSIDE SwiftUI state: the
    /// per-frame scroll callback compares/updates it without invalidating the
    /// view. Only the any-movement check in applyScrollMetrics reads it.
    @State private var preciseOffset = ScrollOffsetBox()

    private static let chartHeight: CGFloat = 150
    private static let gap: CGFloat = 3
    private static let scrollSpace = "usageChartScroll"

    var body: some View {
        // A window of bars fills the viewport; the full series scrolls behind
        // it. The axis labels ride below, tracking the visible window.
        VStack(spacing: 10) {
            GeometryReader { geo in
                let width = geo.size.width
                // slot = one bar + its trailing gap; sized so exactly `window`
                // bars span the viewport. Global max (over ALL bars, not the
                // visible window) keeps bar heights comparable while scrolling.
                let slot = (width + Self.gap) / CGFloat(DayBars.window)
                let barWidth = slot - Self.gap
                let contentWidth = slot * CGFloat(bars.count) - Self.gap
                let maxValue = max(bars.map(barTotal).max() ?? 1, metric == .cost ? 0.000001 : 1)

                let scroll = ScrollView(.horizontal, showsIndicators: false) {
                    ZStack(alignment: .topLeading) {
                        canvas(
                            barWidth: barWidth, maxValue: maxValue,
                            range: drawableRange())
                        if let index = hoverIndex, bars.indices.contains(index),
                           !bars[index].isEmpty {
                            // Dodge the cursor like the model-card tooltip: below
                            // the pointer in the chart's upper half, above it
                            // lower down — pinning to the top kept covering the
                            // hovered area.
                            tooltip(bars[index])
                                .offset(
                                    x: tooltipX(index: index, barWidth: barWidth, viewportWidth: width),
                                    y: hoverY < Self.chartHeight * 0.45
                                        ? hoverY + 16
                                        : hoverY - (tooltipSize.height > 0 ? tooltipSize.height : 120) - 12)
                        }
                    }
                    .frame(width: contentWidth, height: Self.chartHeight)
                    .onContinuousHover { phase in
                        switch phase {
                        case let .active(point):
                            let index = Int(point.x / (barWidth + Self.gap))
                            hoverIndex = bars.indices.contains(index) ? index : nil
                            hoverY = point.y
                        case .ended:
                            hoverIndex = nil
                        }
                    }
                    // Preference-based tracking only reports the initial layout
                    // on macOS — frames aren't republished while scrolling — so
                    // it merely seeds slot/offset for the .v14 path; live
                    // updates come from onScrollGeometryChange below (15+).
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: ScrollMetricsKey.self,
                                value: ScrollMetrics(
                                    offset: -proxy.frame(in: .named(Self.scrollSpace)).minX,
                                    slot: slot))
                        })
                }
                .coordinateSpace(name: Self.scrollSpace)
                .defaultScrollAnchor(.trailing)
                .scrollTargetBehavior(BarSnapTargetBehavior(slot: slot))
                .onPreferenceChange(ScrollMetricsKey.self) { applyScrollMetrics($0) }
                trackingScrollGeometry(scroll)
            }
            .frame(height: Self.chartHeight)

            HStack {
                axisLabel(visibleDate(leadingIndex()))
                Spacer()
                axisLabel(visibleDate(trailingIndex()))
            }
        }
    }

    /// First bar index of the visible window from the current scroll offset,
    /// clamped so the window never runs past the series end. Before any scroll
    /// callback lands (slot still 0) assume the trailing window — that's where
    /// defaultScrollAnchor(.trailing) opens the chart.
    private func leadingIndex() -> Int {
        guard bars.count > DayBars.window else { return 0 }
        guard chartSlot > 0 else { return bars.count - DayBars.window }
        return min(max(scrollSlotIndex, 0), bars.count - DayBars.window)
    }

    private func trailingIndex() -> Int {
        min(leadingIndex() + DayBars.window - 1, bars.count - 1)
    }

    private func visibleDate(_ index: Int) -> String? {
        bars.indices.contains(index) ? bars[index].date : nil
    }

    /// Bars worth drawing at the current scroll position: the visible window
    /// plus a viewport (DayBars.window bars) of buffer each side, so a fling
    /// can't outrun the draw between slot-crossing updates. Draw everything
    /// before the first callback seeds the slot, and on macOS 14, where the
    /// offset never updates after the initial layout (no live culling input —
    /// a stale range would blank out scrolled-to bars).
    private func drawableRange() -> Range<Int> {
        guard #available(macOS 15.0, *), chartSlot > 0 else { return bars.indices }
        let lower = min(max(scrollSlotIndex - DayBars.window, 0), bars.count)
        let upper = min(max(scrollSlotIndex + 2 * DayBars.window, lower), bars.count)
        return lower..<upper
    }

    private func canvas(barWidth: CGFloat, maxValue: Double, range: Range<Int>) -> some View {
        Canvas { context, size in
            let bottom = size.height - 1
            // Axis line.
            context.fill(
                Path(CGRect(x: 0, y: bottom, width: size.width, height: 1)),
                with: .color(.secondary.opacity(0.3)))

            for index in range {
                let bar = bars[index]
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

    /// The offset is in content coordinates, so clamp to the currently visible
    /// viewport rather than the full content width — otherwise the tooltip can
    /// land off screen on a wide, scrolled series. The slot-quantized offset is
    /// exact here: the tooltip only shows while the scroll is at rest (any
    /// movement drops hover), and the snap behavior parks resting offsets on
    /// slot multiples.
    private func tooltipX(index: Int, barWidth: CGFloat, viewportWidth: CGFloat) -> CGFloat {
        let center = CGFloat(index) * (barWidth + Self.gap) + barWidth / 2
        let lower = CGFloat(scrollSlotIndex) * chartSlot
        let upper = max(lower + viewportWidth - Self.tooltipWidth, lower)
        return min(max(center - Self.tooltipWidth / 2, lower), upper)
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
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: TooltipSizeKey.self, value: geo.size)
            })
        .onPreferenceChange(TooltipSizeKey.self) { tooltipSize = $0 }
        .allowsHitTesting(false)
    }

    private struct TooltipSizeKey: PreferenceKey {
        static let defaultValue: CGSize = .zero
        static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
            value = nextValue()
        }
    }

    // MARK: - Scroll tracking

    /// Live offset updates. macOS never republishes GeometryReader frames while
    /// an NSScrollView-backed ScrollView scrolls, so the preference path above
    /// goes stale after the initial layout; the purpose-built scroll-geometry
    /// callback (macOS 15+) is the one that tracks the user's scrolling.
    @ViewBuilder private func trackingScrollGeometry(_ scroll: some View) -> some View {
        if #available(macOS 15.0, *) {
            scroll.onScrollGeometryChange(for: ScrollMetrics.self) { geo in
                ScrollMetrics(
                    offset: geo.contentOffset.x + geo.contentInsets.leading,
                    slot: (geo.containerSize.width + Self.gap) / CGFloat(DayBars.window))
            } action: { _, metrics in
                applyScrollMetrics(metrics)
            }
        } else {
            scroll
        }
    }

    private func applyScrollMetrics(_ metrics: ScrollMetrics) {
        // A tooltip still pinned to a bar sliding out from under the cursor
        // reads as broken — drop hover the moment we scroll, even a sub-slot
        // wiggle. The precise offset lives in the box so this per-pixel check
        // never touches SwiftUI state; every state write below is guarded so
        // an unchanged value can't dirty the view.
        if metrics.offset != preciseOffset.value {
            preciseOffset.value = metrics.offset
            if hoverIndex != nil { hoverIndex = nil }
        }
        if metrics.slot != chartSlot { chartSlot = metrics.slot }
        let index = metrics.slot > 0 ? Int((metrics.offset / metrics.slot).rounded()) : 0
        if index != scrollSlotIndex { scrollSlotIndex = index }
    }

    private struct ScrollMetrics: Equatable {
        var offset: CGFloat = 0
        var slot: CGFloat = 0
    }

    /// Plain reference box: @State keeps the instance alive across body
    /// re-evals, but mutating `value` through the reference bypasses SwiftUI's
    /// change tracking — exactly what the per-pixel scroll callback needs.
    private final class ScrollOffsetBox {
        var value: CGFloat = 0
    }

    private struct ScrollMetricsKey: PreferenceKey {
        static let defaultValue = ScrollMetrics()
        static func reduce(value: inout ScrollMetrics, nextValue: () -> ScrollMetrics) {
            value = nextValue()
        }
    }

    /// Apple-Health-style snap: whether the scroll stops from a slow release or
    /// a fast fling, SwiftUI hands us the deceleration target and we round it to
    /// the nearest bar slot, clamped to the scrollable range.
    private struct BarSnapTargetBehavior: ScrollTargetBehavior {
        let slot: CGFloat
        func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
            guard slot > 0 else { return }
            let maxOffset = max(context.contentSize.width - context.containerSize.width, 0)
            let snapped = (target.rect.origin.x / slot).rounded() * slot
            target.rect.origin.x = min(max(snapped, 0), maxOffset)
        }
    }
}
