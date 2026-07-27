import AppKit
import AgentNotchCore

/// An `NSStatusItem` used as an ORACLE rather than as UI.
///
/// Two questions, one answer:
///
///  1. *Which screen owns the menu bar right now?* Not `NSScreen.main` (that is
///     the screen with the key window, which for an accessory app is nobody's),
///     and not "the built-in display" (wrong the moment the lid is shut). The
///     screen the status bar is drawn on is the screen the menu bar is on, by
///     definition.
///  2. *Is the menu bar there at all?* `currentFrame == nil` is the SINGLE signal
///     for menu-bar-hidden, another app in full screen, and status-item
///     overflow. All three mean the same thing to us — there is nowhere to hang
///     the pill — and all three want the same response: `orderOut`.
///
/// `statusItem.button?.window?.frame` is already global and y-up, so it needs no
/// conversion; that is the whole reason to use a status item instead of doing
/// arithmetic on `NSScreen.screens`.
@MainActor
final class PillAnchorItem {

    private let item: NSStatusItem

    init() {
        // 1 pt requested; macOS enforces a ~17 pt minimum in practice. It must be
        // a REAL item so it participates in menu bar layout and therefore
        // overflows when the bar is full — that overflow is signal, not noise. It
        // carries no image and no title, because the pill is the UI and a second
        // visible affordance would be a second thing to explain.
        item = NSStatusBar.system.statusItem(withLength: 1)
        item.button?.title = ""
        item.button?.image = nil
        // Clicks on the 1 pt sliver do nothing; the pill next to it is the target.
        item.button?.isEnabled = false
        item.isVisible = true
    }

    /// Deliberately no `deinit`. The anchor lives for the process lifetime, and
    /// `removeStatusItem` is main-actor-only while `deinit` is not isolated —
    /// the cleanup would be a concurrency hazard buying nothing.

    /// The anchor's global frame, or nil when there is no menu bar to anchor to.
    var currentFrame: CGRect? {
        guard let window = item.button?.window, window.isVisible else { return nil }
        let frame = window.frame
        // Measured: for the first runloop turn after creation the item's window
        // reports `(0, 0, 17, 0)` — it exists but has not been placed. A zero
        // height therefore means "not yet", which reads the same as "no menu
        // bar" and must be treated as such rather than as a position of (0,0).
        guard frame.width > 0, frame.height > 0 else { return nil }
        // An auto-hidden menu bar parks its window above the top edge rather
        // than hiding it. Requiring an intersection with a real screen catches
        // that without guessing at how far above.
        guard NSScreen.screens.contains(where: { $0.frame.intersects(frame) }) else { return nil }
        return frame
    }

    /// The screen the menu bar is currently on.
    var hostScreen: NSScreen? {
        guard let frame = currentFrame else { return nil }
        let centre = CGPoint(x: frame.midX, y: frame.midY)
        return NSScreen.screens.first { $0.frame.contains(centre) }
            ?? NSScreen.screens.first { $0.frame.intersects(frame) }
    }
}
