import SwiftUI

/// Minimal wrapping row layout for chart/model legends (SwiftUI has no
/// built-in flow container on macOS).
struct FlowLayout: Layout {
    var hSpacing: CGFloat = 10
    var vSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        rows(for: subviews, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        var origin = bounds.origin
        for row in rows(for: subviews, width: bounds.width).rows {
            origin.x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: origin, proposal: ProposedViewSize(size))
                origin.x += size.width + hSpacing
            }
            origin.y += row.height + vSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var height: CGFloat = 0
    }

    private func rows(for subviews: Subviews, width: CGFloat)
        -> (rows: [Row], size: CGSize)
    {
        var rows: [Row] = [Row()]
        var x: CGFloat = 0
        var maxX: CGFloat = 0
        for (index, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                rows.append(Row())
                x = 0
            }
            rows[rows.count - 1].indices.append(index)
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
            x += size.width + hSpacing
            maxX = max(maxX, x - hSpacing)
        }
        let height = rows.reduce(0) { $0 + $1.height } + vSpacing * CGFloat(max(0, rows.count - 1))
        return (rows, CGSize(width: maxX, height: height))
    }
}
