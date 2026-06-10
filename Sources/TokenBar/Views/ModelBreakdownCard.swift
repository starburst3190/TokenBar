import SwiftUI
import TokenBarCore

/// "Models" card: one row per model sorted by cost, with the token-category
/// split as a stacked bar. Port of ModelBreakdownCard.tsx — bar widths use a
/// square-root scale (cache reads dwarf everything linearly; log flattens
/// everything), while the hover help reports true counts and linear shares.
struct ModelBreakdownCard: View {
    let report: ModelReport?
    let colors: ModelColorMap
    var title = "Models"

    @State private var expanded = false

    private static let maxRows = 8

    /// Token-category palette (matches the Tauri .model-seg-* CSS classes).
    private static let tokenKinds: [(label: String, color: String, pick: (ModelReportEntry) -> Int64)] = [
        ("Input", "#3b82f6", { $0.input }),
        ("Output", "#22c55e", { $0.output }),
        ("Cache read", "#f59e0b", { $0.cacheRead }),
        ("Cache write", "#a855f7", { $0.cacheWrite }),
        ("Reasoning", "#ec4899", { $0.reasoning }),
    ]

    var body: some View {
        let rows = (report?.entries ?? []).sorted {
            $0.cost != $1.cost ? $0.cost > $1.cost : $0.total > $1.total
        }
        let totalCost = rows.reduce(0) { $0 + $1.cost }

        DashCard(
            title,
            trailing: {
                Text("\(rows.count) model\(rows.count == 1 ? "" : "s") · \(Format.usd(totalCost))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        ) {
            if rows.isEmpty {
                Text("No model usage in this range")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                legend
                VStack(spacing: 8) {
                    ForEach(
                        expanded ? rows : Array(rows.prefix(Self.maxRows)),
                        id: \.self.rowID
                    ) { entry in
                        row(entry)
                    }
                }
                let hidden = rows.count - min(rows.count, Self.maxRows)
                if hidden > 0 {
                    Button(expanded ? "Show less" : "Show \(hidden) more") {
                        expanded.toggle()
                    }
                    .buttonStyle(.plain)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var legend: some View {
        FlowLayout(hSpacing: 8, vSpacing: 3) {
            ForEach(Self.tokenKinds, id: \.label) { kind in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color(hex: kind.color))
                        .frame(width: 7, height: 7)
                    Text(kind.label)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ entry: ModelReportEntry) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color(hex: colors.color(entry.provider, entry.model)))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.model)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                segmentBar(entry)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(Format.compactTokens(entry.total))
                    .font(.caption.monospacedDigit())
                Text(Format.usd(entry.cost))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Color(hex: "#22c55e"))
            }
        }
        .help(helpText(entry))
    }

    /// sqrt-scaled stacked category bar.
    private func segmentBar(_ entry: ModelReportEntry) -> some View {
        let segments = Self.tokenKinds
            .map { (color: $0.color, value: $0.pick(entry)) }
            .filter { $0.value > 0 }
        let scaleTotal = segments.reduce(0.0) { $0 + Double($1.value).squareRoot() }
        return GeometryReader { geo in
            HStack(spacing: 1) {
                ForEach(segments.indices, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color(hex: segments[i].color))
                        .frame(
                            width: scaleTotal > 0
                                ? max(1, geo.size.width * Double(segments[i].value).squareRoot() / scaleTotal)
                                : 0)
                }
            }
        }
        .frame(height: 6)
    }

    /// True linear shares for the system tooltip (the rich floating tooltip
    /// from the web app is deferred to the polish phase).
    private func helpText(_ entry: ModelReportEntry) -> String {
        let head = "\(entry.model) — \(ClientRegistry.style(entry.client).displayName) · \(entry.provider)"
        let total = "\(Format.exactTokens(entry.total)) tokens · \(Format.usd(entry.cost))"
        let kinds = Self.tokenKinds
            .map { (label: $0.label, value: $0.pick(entry)) }
            .filter { $0.value > 0 }
            .map { kind in
                let pct = entry.total > 0 ? Double(kind.value) / Double(entry.total) * 100 : 0
                return "\(kind.label): \(Format.compactTokens(kind.value)) · \(Int(pct.rounded()))%"
            }
        return ([head, total] + kinds).joined(separator: "\n")
    }
}

extension ModelReportEntry {
    /// Stable row identity across re-sorts (client+model+provider triple).
    var rowID: String { "\(client)|\(model)|\(provider)" }
}
