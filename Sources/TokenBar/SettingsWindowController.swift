import AppKit
import TokenBarCore
import SwiftUI

/// Owns the standalone settings window (gear button, Cmd-comma, `--settings`).
/// One window per app, kept alive across closes so its position persists;
/// `show()` re-fronts it. The popover stays `.transient` and uninvolved —
/// the window carries its own live preview instead of pinning the popover.
@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()

    private var window: NSWindow?
    // AnyView so the live UI can be swapped for a static placeholder on close.
    private var host: NSHostingController<AnyView>?
    private var closeObserver: NSObjectProtocol?
    private var scaleObserver: NSObjectProtocol?

    /// A place in Settings a caller wants brought into view. The intro card
    /// uses it so "Open Settings" lands on the section it just described
    /// instead of the top of the first page.
    enum Destination {
        case discord

        var page: SettingsPanel.Page { .general }
        /// Matched by a `.id(...)` on the section itself.
        var anchor: String { "settings.section.discord" }
    }

    func show(scrollingTo destination: Destination? = nil) {
        let existing = self.window
        let window = existing ?? makeWindow(destination: destination)
        self.window = window
        // Reopening a kept-alive window: reinstall the live settings UI that
        // the previous close swapped out for a static placeholder. (Closing
        // only orders the window out; leaving the live content mounted let its
        // preview TimelineView(.periodic) keep re-rendering off-screen at up
        // to 40fps and pin a core in the background — the chronic CPU spin.)
        if existing != nil {
            // `.id` only when a destination is requested: a fresh identity
            // re-runs the view's `@State`, which is what selects the page and
            // fires the scroll — and is exactly what an ordinary reopen must
            // NOT do, since it would discard the page the user was last on.
            host?.rootView = destination.map {
                AnyView(SettingsWindowView(destination: $0).id($0.anchor + UUID().uuidString))
            } ?? AnyView(SettingsWindowView())
        }
        let firstShow = !window.isVisible
        // Accessory apps are never frontmost; activate or the window opens
        // behind whatever app currently has focus.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // Dead-center on open (but never yank an already-open window).
        // NSWindow.center() sits noticeably above center, so place by hand.
        // The frame is final here because `makeWindow` sized it to include the
        // title bar — see there for why sizing it any other way left this
        // centring half a title bar off.
        if firstShow {
            center(window)
        }
    }

    private func center(_ window: NSWindow) {
        guard let screen = window.screen ?? NSScreen.main ?? NSScreen.screens.first
        else { return }
        let visible = screen.visibleFrame
        window.setFrameOrigin(NSPoint(
            x: visible.midX - window.frame.width / 2,
            y: visible.midY - window.frame.height / 2))
    }

    /// The area the SwiftUI content asks for at the current scale — the
    /// `contentLayoutRect`, i.e. what is left of the frame once the title bar
    /// has taken its band.
    private static func scaledContentSize() -> NSSize {
        let scale = PopoverScale.current.factor
        return NSSize(
            width: (SettingsWindowMetrics.width * scale).rounded(),
            height: (SettingsWindowMetrics.height * scale).rounded())
    }

    /// Height the title bar takes out of the frame. Measured rather than
    /// assumed: it is a system metric, and it is zero before the style mask
    /// says the window is titled.
    private static func titleBarHeight(_ window: NSWindow) -> CGFloat {
        window.frame.height - window.contentLayoutRect.height
    }

    /// Resize the window to the scaled content and keep its centre where it
    /// was, rather than growing off one edge.
    private func applyScale() {
        guard let window else { return }
        let target = Self.scaledContentSize()
        // Measured against `contentLayoutRect`, NOT `contentView.frame`. Under
        // `.fullSizeContentView` the content VIEW is inflated to run under the
        // title bar (580 -> 612 at 1x), so it never equalled a target
        // expressed in content terms and this guard never once held. Every
        // `UserDefaults` change — the app writes them while it polls — then
        // resized and re-placed the window, and each pass lost half a title
        // bar: the settings window walked down the screen on its own.
        guard window.contentLayoutRect.size != target else { return }
        let centre = NSPoint(x: window.frame.midX, y: window.frame.midY)
        // One `setFrame` to the final geometry instead of `setContentSize` plus
        // a re-origin: sizing in two steps leaves the window briefly a title
        // bar short, and AppKit anchors a resize to the top-left, so the
        // intermediate state moves the window before the second step measures
        // it.
        let height = target.height + Self.titleBarHeight(window)
        window.setFrame(
            NSRect(
                x: (centre.x - target.width / 2).rounded(),
                y: (centre.y - height / 2).rounded(),
                width: target.width, height: height),
            display: true)
    }

    private func makeWindow(destination: Destination? = nil) -> NSWindow {
        let host = NSHostingController(rootView: AnyView(SettingsWindowView(destination: destination)))
        self.host = host
        let window = NSWindow(contentViewController: host)
        window.title = "TokenBar Settings".localized
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        // The glass backdrop runs under the title bar (the popover look);
        // scroll views inset their content via the safe area.
        window.titlebarAppearsTransparent = true
        // macOS 26 draws the native title flush left next to the traffic lights
        // and an opaque title bar only trades the seamless glass for a solid
        // band without centering it, so show no title at all — the sidebar and
        // the window's own content already say what this is. `window.title`
        // stays set for Mission Control and the Window menu.
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        // Sized here, AFTER the style mask, and from the metrics rather than
        // `host.view.fittingSize`. Two reasons, both learned from this window
        // opening a half title bar low:
        //
        // `NSWindow(contentViewController:)` sizes lazily, so the fitting size
        // read before the window has a title bar is the bare content — and
        // under `.fullSizeContentView` the content rect IS the frame, so
        // passing that bare height leaves the SwiftUI content a title bar
        // short. It then inflated the window on its first layout pass, after
        // `show()` had already centred the smaller frame, and AppKit anchors
        // that growth to the top-left — so the finished window sat half a
        // title bar below centre.
        //
        // Adding the measured title bar up front means the frame `show()`
        // centres is the frame the content wants, and no layout pass resizes
        // it afterwards.
        let content = Self.scaledContentSize()
        window.setContentSize(content)
        window.setContentSize(NSSize(
            width: content.width, height: content.height + Self.titleBarHeight(window)))
        // Swap the live UI for a static, same-size placeholder when the window
        // closes so its preview timelines + polling .tasks are torn down (a
        // kept-alive closed window otherwise keeps rendering in the
        // background); show() reinstalls the live UI on the next open.
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.host?.rootView = AnyView(Color.clear.frame(
                    width: SettingsWindowMetrics.width, height: SettingsWindowMetrics.height))
            }
        }
        scaleObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.applyScale() }
            }
        }
        // No didResize re-center one-shot here: it existed for the
        // .fullSizeContentView title-bar inflation (580 -> 612) that this
        // window's plain titled style no longer produces — with the content
        // rect final at creation, a resize observer would only misfire when
        // applyScale() legitimately resizes the window later.
        return window
    }
}
