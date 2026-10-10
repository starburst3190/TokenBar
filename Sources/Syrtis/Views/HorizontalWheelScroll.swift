import AppKit
import SwiftUI

/// Lets a plain vertical mouse wheel scroll a horizontal `ScrollView`. The
/// client-tab row scrolls horizontally, but a mouse without a horizontal-scroll
/// device only emits vertical wheel deltas, so those users otherwise can't move
/// the row. A trackpad (which sends horizontal/precise deltas) is left
/// untouched, and the redirect only fires while the cursor is over this row.
///
/// Place inside the horizontal ScrollView's content so `enclosingScrollView`
/// resolves to that row's NSScrollView (the OverlayScroller pattern).
struct HorizontalWheelScroll: NSViewRepresentable {
    /// Scroll in whole steps of this width, landing on its multiples: the
    /// usage chart passes its bar slot so a wheel moves it bar by bar, as its
    /// scroll target behavior does for a trackpad. A programmatic scroll skips
    /// that behavior, and the chart's tooltip anchoring assumes a slot-aligned
    /// offset. Nil scrolls freely by the wheel's own distance.
    var quantum: CGFloat? = nil

    func makeNSView(context: Context) -> WheelRedirectView { WheelRedirectView() }
    func updateNSView(_ view: WheelRedirectView, context: Context) {
        view.quantum = quantum.flatMap { $0 > 0 ? $0 : nil }
    }

    /// The clamped horizontal origin after stepping by `step`, and whether it
    /// actually moved. Pure so tests can exercise the boundary case (already
    /// scrolled all the way to an edge) without simulating an `NSEvent`.
    ///
    /// FLAT-HEATMAP round 4, FIX 2: at either scroll edge (e.g. the heatmap's
    /// default trailing-scrolled position) the old code clamped the origin
    /// and unconditionally reported the event as consumed, even when the
    /// clamped value was identical to the current one — swallowing the
    /// dashboard's *vertical* scroll on the very first wheel tick over a
    /// heatmap already parked at its right edge.
    static func clampedScroll(originX: CGFloat, step: CGFloat, maxX: CGFloat) -> (newOriginX: CGFloat, moved: Bool) {
        let newOriginX = min(max(0, originX - step), maxX)
        return (newOriginX, newOriginX != originX)
    }

    /// Whole steps for one wheel event in quantum mode, and the remainder to
    /// carry. A line-based wheel moves one step per notch (more when the
    /// system accelerates it); a smooth-scrolling mouse reports points, which
    /// add up until they cover a step. A reversal drops the carried remainder,
    /// so turning the wheel back moves back on the first full step.
    static func quantumSteps(
        pending: CGFloat, delta: CGFloat, precise: Bool, quantum: CGFloat
    ) -> (steps: Int, pending: CGFloat) {
        guard delta != 0, quantum > 0 else { return (0, pending) }
        guard precise else {
            return (Int(delta.rounded(.awayFromZero)), 0)
        }
        let carried = (pending == 0 || (pending > 0) == (delta > 0)) ? pending : 0
        let total = carried + delta
        let steps = Int((total / quantum).rounded(.towardZero))
        return (steps, total - CGFloat(steps) * quantum)
    }

    /// The origin `steps` whole quanta from the current one, measured from the
    /// nearest multiple so a slightly misaligned origin realigns, clamped to
    /// the scrollable range. A positive step moves toward the leading edge,
    /// matching `clampedScroll`'s sign.
    static func quantizedScroll(
        originX: CGFloat, steps: Int, quantum: CGFloat, maxX: CGFloat
    ) -> (newOriginX: CGFloat, moved: Bool) {
        let index = (originX / quantum).rounded()
        let target = (index - CGFloat(steps)) * quantum
        let newOriginX = min(max(0, target), maxX)
        return (newOriginX, newOriginX != originX)
    }

    @MainActor
    final class WheelRedirectView: NSView {
        private var monitor: Any?
        var quantum: CGFloat?
        /// Smooth-scroll distance not yet worth a whole quantum.
        private var pending: CGFloat = 0

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                removeMonitor()
            } else if monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) {
                    [weak self] event in
                    guard let self else { return event }
                    return self.redirect(event) ? nil : event
                }
            }
        }

        /// Returns true when the event was consumed as a horizontal scroll.
        private func redirect(_ event: NSEvent) -> Bool {
            guard let scroll = enclosingScrollView,
                let window, event.window === window
            else { return false }
            // A trackpad scroll carries gesture phases; a mouse wheel — even a
            // high-res one like the MX Master — does not. Restrict the redirect
            // to phase-less mouse wheels so trackpad swipes keep full native
            // behavior. (hasPreciseScrollingDeltas can't tell them apart: a
            // high-res mouse reports precise deltas for smooth scrolling too.)
            guard event.phase.isEmpty, event.momentumPhase.isEmpty else { return false }
            // The vertical wheel reports a clean vertical-only delta; the
            // horizontal thumb wheel (deltaX != 0) is left to scroll natively.
            guard event.scrollingDeltaX == 0 else { return false }
            let dy = event.scrollingDeltaY
            guard dy != 0 else { return false }
            // Only redirect while the pointer is over this row's scroll view.
            let point = scroll.convert(event.locationInWindow, from: nil)
            guard scroll.bounds.contains(point) else { return false }

            let clip = scroll.contentView
            let maxX = max(0, (scroll.documentView?.frame.width ?? 0) - clip.bounds.width)
            guard maxX > 0 else { return false }
            if let quantum {
                let originX = clip.bounds.origin.x
                // Toward an edge the origin already sits on: let the event fall
                // through to the parent (vertical) scroll view, as below.
                if (dy > 0 && originX <= 0) || (dy < 0 && originX >= maxX) {
                    pending = 0
                    return false
                }
                let (steps, carry) = HorizontalWheelScroll.quantumSteps(
                    pending: pending, delta: dy,
                    precise: event.hasPreciseScrollingDeltas, quantum: quantum)
                pending = carry
                // Short of a whole step: consumed, so the page does not scroll
                // vertically while the distance adds up.
                guard steps != 0 else { return true }
                let (newOriginX, moved) = HorizontalWheelScroll.quantizedScroll(
                    originX: originX, steps: steps, quantum: quantum, maxX: maxX)
                if moved {
                    var origin = clip.bounds.origin
                    origin.x = newOriginX
                    clip.setBoundsOrigin(origin)
                    scroll.reflectScrolledClipView(clip)
                }
                return true
            }
            // Precise (smooth) deltas are already in points; coarse wheel deltas
            // are in lines and need scaling for a comfortable step.
            let step = event.hasPreciseScrollingDeltas ? dy : dy * 16
            let (newOriginX, moved) = HorizontalWheelScroll.clampedScroll(
                originX: clip.bounds.origin.x, step: step, maxX: maxX)
            // Already at this edge — let the event fall through to the parent
            // (vertical) scroll view instead of silently eating it.
            guard moved else { return false }
            var origin = clip.bounds.origin
            origin.x = newOriginX
            clip.setBoundsOrigin(origin)
            scroll.reflectScrolledClipView(clip)
            return true
        }

        private func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
        // The monitor is torn down in viewDidMoveToWindow when the row leaves
        // its window (popover close), so no deinit cleanup is needed — and a
        // nonisolated deinit cannot touch the non-Sendable monitor handle.
    }
}
