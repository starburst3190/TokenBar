import AppKit
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

    func show() {
        let existing = self.window
        let window = existing ?? makeWindow()
        self.window = window
        // Reopening a kept-alive window: reinstall the live settings UI that
        // the previous close swapped out for a static placeholder. (Closing
        // only orders the window out; leaving the live content mounted let its
        // preview TimelineView(.periodic) keep re-rendering off-screen at up
        // to 40fps and pin a core in the background — the chronic CPU spin.)
        if existing != nil {
            host?.rootView = AnyView(SettingsWindowView())
        }
        let firstShow = !window.isVisible
        // Accessory apps are never frontmost; activate or the window opens
        // behind whatever app currently has focus.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // Dead-center on open (but never yank an already-open window).
        // NSWindow.center() sits noticeably above center, so place by hand.
        // The frame is final here: the plain titled style has no
        // .fullSizeContentView safe-area inflation to wait out.
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

    /// Match the window's content size to the scaled SwiftUI frame (the title
    /// bar lives outside the content rect, so no compensation is needed) and
    /// keep the window centered where it was rather than growing off one edge.
    private func applyScale() {
        guard let window else { return }
        let scale = PopoverScale.current.factor
        let newSize = NSSize(
            width: (SettingsWindowMetrics.width * scale).rounded(),
            height: (SettingsWindowMetrics.height * scale).rounded())
        guard window.contentView?.frame.size != newSize else { return }
        let center = NSPoint(x: window.frame.midX, y: window.frame.midY)
        window.setContentSize(newSize)
        window.setFrameOrigin(NSPoint(
            x: (center.x - window.frame.width / 2).rounded(),
            y: (center.y - window.frame.height / 2).rounded()))
    }

    private func makeWindow() -> NSWindow {
        let host = NSHostingController(rootView: AnyView(SettingsWindowView()))
        self.host = host
        let window = NSWindow(contentViewController: host)
        // NSWindow(contentViewController:) sizes lazily (the frame is still
        // 1x0 at show time, which broke the centering math) — force the
        // SwiftUI fitting size up front.
        window.setContentSize(host.view.fittingSize)
        window.title = "TokenBar Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
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
