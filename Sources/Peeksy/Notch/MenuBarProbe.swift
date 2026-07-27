import PeeksyCore
import AppKit

/// Two questions about the menu bar, answered without taking any of it.
///
///  1. *Which screen should the pill live on?*
///  2. *Is there a menu bar there at all?* — the single signal for a hidden bar
///     and for another app in full screen, both of which mean there is nowhere
///     to hang the pill and both of which want `orderOut`.
///
/// Replaces `PillAnchorItem`, which answered the same questions with a real
/// `NSStatusItem`. That item cost the user ~17 pt of menu bar (1 pt requested,
/// enforced to 17), and its cost was inseparable from its signal: the frame it
/// reported only existed while it occupied layout, so `length = 0` and
/// `isVisible = false` blind the oracle rather than shrinking it. There was no
/// middle ground — keep the 17 pt or delete the item.
///
/// It also carried a bug worth naming, because it is half the reason this file
/// exists. A `length: 1` item is the FIRST thing macOS drops when the bar fills.
/// The old code read that as "there is no menu bar" and ordered the panel out
/// permanently, so the app switched itself off on exactly the machines where a
/// crowded menu bar made it most useful — and logged nothing. Overflow is now
/// somebody else's condition to have, and ours to yield to deliberately.
@MainActor
final class MenuBarProbe {

    /// One answer to both questions, from ONE window-list sample.
    ///
    /// Answering them separately meant sampling per screen per question; this is
    /// a 24/7 app and the scan, though cheap, is not free.
    struct Reading {
        /// The screen the pill belongs on, or nil if there is no menu bar
        /// anywhere.
        let screen: NSScreen?
        /// The menu bar's rect on `screen`, AppKit global.
        let rect: CGRect?
        /// `frame.maxY - visibleFrame.maxY` for `screen` — an independent second
        /// opinion, reported rather than acted on.
        let inset: CGFloat?

        var isPresent: Bool { rect != nil }
    }

    private let scanner: MenuBarScanner

    init(scanner: MenuBarScanner) {
        self.scanner = scanner
    }

    /// One sample, both answers.
    ///
    /// Screen preference is: the notched panel IF the menu bar is on it, then
    /// whichever display does have the menu bar, then `NSScreen.screens.first`.
    ///
    /// Preferring the notch is deliberate — the product is a pill beside a
    /// hardware notch, and the notch does not move — but preferring it only when
    /// the bar is actually there matters just as much: drawing a pill into a
    /// strip that is not a menu bar would be worse than following the bar to an
    /// external, which is what the old anchor did.
    func read() -> Reading {
        let windows = scanner.sample()
        let primaryMaxY = scanner.primaryScreenMaxY
        let screens = NSScreen.screens

        var hosting: (screen: NSScreen, rect: CGRect)?
        for screen in screens {
            let metrics = metrics(for: screen)
            guard let rect = MenuBarScan.menuBarWindow(
                in: metrics,
                bandHeight: bandHeight(for: metrics),
                windows: windows,
                primaryScreenMaxY: primaryMaxY)
            else { continue }
            // First match wins unless a notched panel turns up later.
            if hosting == nil { hosting = (screen, rect) }
            if metrics.hasNotch {
                hosting = (screen, rect)
                break
            }
        }

        if let hosting {
            return Reading(screen: hosting.screen,
                           rect: hosting.rect,
                           inset: inset(on: hosting.screen))
        }
        // No menu bar anywhere. Still name a screen, so the geometry the panel
        // was built against stays valid while it is ordered out — `screens.first`
        // is documented as the display containing the menu bar, and is the last
        // resort rather than the first because `NSScreen.main` is the screen with
        // the KEY window, which for an accessory app is nobody's.
        let fallback = screens.first { metrics(for: $0).hasNotch } ?? screens.first
        return Reading(screen: fallback, rect: nil, inset: fallback.map(inset(on:)))
    }

    /// `frame.maxY - visibleFrame.maxY` — the menu bar's inset, measured 33.0
    /// with the bar shown on a 32 pt band.
    ///
    /// `ScreenMetrics.frame`'s "NEVER `visibleFrame`" rule still stands: that
    /// rule is about DERIVING geometry, where `visibleFrame` subtracts the very
    /// band we draw in. Reading the DIFFERENCE as a presence hint is a different
    /// use, and without this note someone will come along and "fix" the line.
    func inset(on screen: NSScreen) -> CGFloat {
        screen.frame.maxY - screen.visibleFrame.maxY
    }

    // MARK: - Private

    private func bandHeight(for metrics: ScreenMetrics) -> CGFloat {
        metrics.hasNotch ? metrics.safeAreaTop : NotchLayout.default.fallbackBandHeight
    }

    private func metrics(for screen: NSScreen) -> ScreenMetrics {
        ScreenMetrics(
            displayID: ScreenMetricsReader.displayID(of: screen),
            frame: screen.frame,
            auxLeftWidth: screen.auxiliaryTopLeftArea?.width ?? 0,
            auxRightWidth: screen.auxiliaryTopRightArea?.width ?? 0,
            safeAreaTop: screen.safeAreaInsets.top
        )
    }
}
