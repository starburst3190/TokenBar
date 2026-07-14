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

    /// Re-anchor the panel without rebuilding its content — the cheap path
    /// for continuous hover, where only the cursor moved. Continuous-hover
    /// events arrive per pixel; rebuilding the content view for each would
    /// re-render the whole layer at pointer frequency for identical content.
    /// No-op unless `owner` still holds the tooltip.
    func move(owner: AnyHashable, to anchor: CGPoint) {
        guard self.owner == owner else { return }
        self.anchor = anchor
    }

    /// Whether `owner` currently holds a visible tooltip — lets a card decide
    /// between the `move` fast path and a full `show` (e.g. after `clear()`
    /// dropped the panel out from under a still-hovering cursor).
    func isActive(owner: AnyHashable) -> Bool {
        self.owner == owner && content != nil
    }

    func hide(owner: AnyHashable) {
        guard self.owner == owner else { return }
        self.owner = nil
        self.anchor = nil
        self.content = nil
    }

    /// Unconditional reset for container-level invalidation — a tab switch or
    /// data refresh replaces the content under the cursor, and no single owner
    /// is in a position to clean up a panel built from the old data.
    func clear() {
        owner = nil
        anchor = nil
        content = nil
    }
}

/// Renders the active tooltip in the popover's scroll-viewport space. Hangs a
/// constant gap below the cursor while the whole panel fits above the viewport
/// floor; once it no longer fits, only the anchored edge flips — the panel's
/// bottom edge then rides the same gap *above* the cursor, at the same
/// horizontal position.
///
/// Anchoring an edge a fixed gap from the pointer in both modes is what keeps
/// the panel glued to the cursor, and because the flipped panel's bottom stays
/// above the cursor it can never slip behind the footer bar at the viewport
/// floor. Clamping to the floor instead would pin low-cursor tooltips to one
/// frozen spot with the pointer buried inside.
///
/// Placement anchors the panel's *edge* via frame alignment rather than
/// arithmetic on a measured height: tooltips vary in height and the measurement
/// lags a frame behind content swaps, so any `anchor.y - h` math intermittently
/// strands the panel far from the cursor. Here the stale height can only sway
/// the below/above choice for a frame — never where the anchored edge lands.
struct HoverTooltipLayer: View {
    @Environment(TooltipHost.self) private var host
    /// The scroll viewport's size (measured by the overlay's GeometryReader).
    let viewportSize: CGSize

    @State private var size: CGSize = .zero

    /// Breathing room between the cursor and the panel's near edge.
    private static let gap: CGFloat = 8

    var body: some View {
        if let content = host.content, let anchor = host.anchor {
            let below = fitsBelow(anchor: anchor)
            content
                .fixedSize()
                .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
                // Zero-sized anchor frame: the alignment hangs the panel off the
                // chosen edge of a point, so the anchored edge lands exactly at
                // the offset regardless of the panel's real size.
                .frame(width: 0, height: 0, alignment: below ? .top : .bottom)
                .offset(anchorPoint(anchor: anchor, below: below))
                .allowsHitTesting(false)
        }
    }

    /// Whether the whole panel fits between the cursor and the viewport floor
    /// (the footer divider). The measured height steers only this choice.
    private func fitsBelow(anchor: CGPoint) -> Bool {
        let h = size.height > 0 ? size.height : 160
        return anchor.y + Self.gap + h <= viewportSize.height
    }

    /// The point the panel hangs from: its top-centre below the cursor, its
    /// bottom-centre above — the same horizontal position either way.
    private func anchorPoint(anchor: CGPoint, below: Bool) -> CGSize {
        let w = size.width > 0 ? size.width : 210
        // Centre on the cursor, slid horizontally to stay inside the popover.
        let cx = min(max(anchor.x, w / 2), max(w / 2, viewportSize.width - w / 2))
        return CGSize(width: cx, height: below ? anchor.y + Self.gap : anchor.y - Self.gap)
    }
}
