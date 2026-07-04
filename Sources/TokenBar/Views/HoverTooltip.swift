import SwiftUI

/// Shared host for the popover's hover tooltip. Cards report the hovered
/// content and the cursor's position (in the scroll-viewport coordinate space,
/// `PopoverViewport.space`) here; PopoverView renders a single `HoverTooltipLayer`
/// above the scroll area. Hosting the panel at the root — rather than as an
/// overlay inside each card — is what lets it float over neighbouring cards
/// without their borders cutting through it, and lets it stop cleanly at the
/// visible viewport bottom instead of being clipped by the scroll edge or
/// hidden behind the footer bar.
@MainActor
@Observable
final class TooltipHost {
    fileprivate var anchor: CGPoint?
    fileprivate var content: AnyView?
    /// Whoever currently owns the tooltip, so a stale `.ended` from a row we
    /// already left can't clear the tooltip the next row just claimed.
    @ObservationIgnored private var owner: AnyHashable?

    func show(owner: AnyHashable, at anchor: CGPoint, @ViewBuilder content: () -> some View) {
        self.owner = owner
        self.anchor = anchor
        self.content = AnyView(content())
    }

    func hide(owner: AnyHashable) {
        guard self.owner == owner else { return }
        self.owner = nil
        self.anchor = nil
        self.content = nil
    }
}

/// Renders the active tooltip in the popover's scroll-viewport space. Sits just
/// below the cursor and *slides* back into view when it would overrun an edge,
/// rather than flipping to the far side of the cursor.
///
/// Sliding is what makes it feel natural: the panel stays glued to the cursor
/// with no sudden jumps, where a flip would teleport the whole panel-height to
/// the other side the instant the near edge crossed the threshold — the same
/// cursor position landing the panel in wildly different spots. Clamping to the
/// viewport (whose bottom edge is the footer divider) also guarantees the panel
/// can never slip behind the footer bar. When the cursor sits low the panel
/// comes to rest with its bottom on the viewport floor and the cursor tucked
/// just inside it; that small overlap is the deliberate trade for keeping the
/// panel close instead of leaving a large empty gap.
struct HoverTooltipLayer: View {
    @Environment(TooltipHost.self) private var host
    /// The scroll viewport's size (measured by the overlay's GeometryReader).
    let viewportSize: CGSize

    @State private var size: CGSize = .zero

    /// Breathing room between the cursor and the panel's top edge while it hangs
    /// below; absorbed once the panel slides up against the viewport floor.
    private static let gap: CGFloat = 8

    var body: some View {
        if let content = host.content, let anchor = host.anchor {
            content
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: SizeKey.self, value: geo.size)
                    })
                .onPreferenceChange(SizeKey.self) { size = $0 }
                .offset(offset(anchor: anchor))
                .allowsHitTesting(false)
        }
    }

    private func offset(anchor: CGPoint) -> CGSize {
        // Fallbacks cover the first frame before the size preference reports.
        let w = size.width > 0 ? size.width : 210
        let h = size.height > 0 ? size.height : 160
        // Centre on the cursor horizontally, hang just below it vertically, then
        // slide back inside the viewport on every edge. `max(0, …)` guards the
        // case where the panel is taller/wider than the viewport itself.
        let x = min(max(anchor.x - w / 2, 0), max(0, viewportSize.width - w))
        let y = min(max(anchor.y + Self.gap, 0), max(0, viewportSize.height - h))
        return CGSize(width: x, height: y)
    }

    private struct SizeKey: PreferenceKey {
        static let defaultValue: CGSize = .zero
        static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
            value = nextValue()
        }
    }
}
