import AppKit
import SwiftUI

/// Keeps the panel in one place.
///
/// The menu bar lines the panel up with the left edge of its item, both when
/// it opens and whenever the item changes width while it's open. The item
/// grows and shrinks with its text ("Plan your day", "Write report  24:59"),
/// and items on the right of the menu bar grow to the left, so that edge
/// moves: pressing play or ticking off a task slid the open panel sideways,
/// and it opened somewhere different each time. The item's right edge stays
/// put, so the panel lines up with that instead.
struct PanelAnchor: NSViewRepresentable {
    func makeNSView(context: Context) -> AnchorView { AnchorView() }
    func updateNSView(_ nsView: AnchorView, context: Context) {}

    final class AnchorView: NSView {
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            // The menu bar places the panel when it opens, and again whenever
            // the item changes width while it's open, so line it up after
            // every move. These arrive in the middle of the move, before
            // anything is drawn, so the panel never shows in the wrong place.
            // Moving it here moves it again, but by then it's already in place.
            observers = [NSWindow.didMoveNotification, NSWindow.didBecomeKeyNotification].map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: nil) { [weak self] _ in
                    MainActor.assumeIsolated { self?.align() }
                }
            }
        }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }

        private func align() {
            // Not placed yet: a new panel sits at the screen's corner until
            // the menu bar positions it.
            guard let window, window.frame.origin != .zero,
                  let item = statusItemFrame(for: window) else { return }
            let screen = window.screen ?? NSScreen.screens.first { $0.frame.intersects(item) }
            var x = item.maxX - window.frame.width
            if let bounds = screen?.visibleFrame {
                x = min(max(x, bounds.minX), bounds.maxX - window.frame.width)
            }
            guard abs(window.frame.minX - x) > 0.5 else { return }
            window.setFrameOrigin(NSPoint(x: x, y: window.frame.minY))
        }

        /// The menu bar item the panel hangs from. Each display's menu bar has
        /// its own copy, so it's the one on the panel's screen, nearest the
        /// panel.
        private func statusItemFrame(for window: NSWindow) -> NSRect? {
            NSApp.windows
                .filter { $0.className == "NSStatusBarWindow" && $0.isVisible }
                .map(\.frame)
                .filter { window.screen == nil || window.screen!.frame.intersects($0) }
                .min { abs($0.midX - window.frame.midX) < abs($1.midX - window.frame.midX) }
        }
    }
}
