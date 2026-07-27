import PeeksyCore
import AppKit
import CoreGraphics

/// The CoreGraphics half of "where is everybody else's menu bar icon".
///
/// Same shape as `ScreenMetricsReader`: one system read, no policy. Everything
/// that decides anything lives in `MenuBarScan`, which is pure and tested.
///
/// Measured cost: 0.31 ms per call including the array walk, which is why this
/// can hang off a timer that already exists rather than needing one of its own.
@MainActor
final class MenuBarScanner {

    /// The layer our own status-bar-adjacent window was last seen on, if we ever
    /// get to observe one. Lets the filter self-calibrate rather than trusting
    /// the literal 25 forever.
    private var observedStatusLayer: Int?

    /// Every on-screen window, reduced to the four keys we read.
    ///
    /// `kCGWindowOwnerName` and `kCGWindowOwnerPID` are NOT read. On macOS 26
    /// both report Control Center for every status item, including ours
    /// (FB18327911), so filtering or excluding by owner is silently wrong.
    /// `kCGWindowName` is not read either — it requires a Screen Recording grant,
    /// and this app's permission surface is Automation→Terminal and nothing else.
    func sample() -> [StatusWindow] {
        guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
            as? [[String: Any]]
        else { return [] }

        return raw.compactMap { window in
            guard let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  let number = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let boundsDict = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { return nil }
            let alpha = (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            return StatusWindow(windowID: number, layer: layer, cgBounds: bounds, alpha: alpha)
        }
    }

    /// AppKit's global space is y-up from the bottom of the display at (0,0);
    /// CG's is y-down from the top of the same display. They differ by exactly
    /// that display's height.
    var primaryScreenMaxY: CGFloat {
        let screens = NSScreen.screens
        let primary = screens.first {
            abs($0.frame.origin.x) < 0.5 && abs($0.frame.origin.y) < 0.5
        }
        return (primary ?? screens.first)?.frame.maxY ?? 0
    }

    /// One sample, filtered to a display's menu bar and judged for trust.
    ///
    /// `calibration` should be a window whose true AppKit frame the caller knows
    /// — our own panel. Comparing it against its own converted CG bounds is a
    /// live check on the bounds and the y-flip together, which matters because
    /// macOS 26 already changed what this API reports once.
    func occupancy(
        screen: ScreenMetrics,
        bandHeight: CGFloat,
        calibration: (windowID: UInt32, appKitFrame: CGRect)? = nil
    ) -> MenuBarOccupancy {
        let windows = sample()
        return MenuBarScan.occupancy(
            windows: windows,
            screen: screen,
            bandHeight: bandHeight,
            primaryScreenMaxY: primaryScreenMaxY,
            statusLayer: observedStatusLayer ?? MenuBarScan.defaultStatusLayer,
            calibration: calibration)
    }

    /// Teach the scanner which layer status items are on, from a window we know
    /// is one. Cheap insurance against the literal 25 going stale.
    func calibrateStatusLayer(from windows: [StatusWindow], knownStatusItem id: UInt32) {
        guard let item = windows.first(where: { $0.windowID == id }) else { return }
        observedStatusLayer = item.layer
    }
}
