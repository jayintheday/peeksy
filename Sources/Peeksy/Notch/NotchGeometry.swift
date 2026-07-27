import PeeksyCore
import AppKit

// The AppKit shell around the pure geometry in
// `Sources/PeeksyCore/Notch/NotchGeometry.swift`.
//
// Everything here is either an `NSScreen` read or a log line. The derivation,
// the invariant and the two coordinate conversions live in the core so they can
// be tested against synthetic 14"/16"/external/negative-origin displays instead
// of against whichever Mac happens to run the suite.

/// Turns an `NSScreen` into `ScreenMetrics`, and owns the one piece of state the
/// pure side must not have.
@MainActor
final class ScreenMetricsReader {

    /// Last good `safeAreaInsets.top`, per display.
    ///
    /// That inset transiently reports 0 on a notched panel — observed during
    /// wake and during display reconfiguration. A zero there flips `hasNotch`
    /// false, which collapses the geometry to the non-notch fallback and throws
    /// the pill into the middle of the screen for a frame or two. One dictionary
    /// entry per display removes the entire class of glitch.
    private var safeAreaCache: [UInt32: CGFloat] = [:]

    func metrics(for screen: NSScreen) -> ScreenMetrics {
        let displayID = Self.displayID(of: screen)
        let reported = screen.safeAreaInsets.top
        let safeAreaTop: CGFloat
        if reported > 0 {
            safeAreaCache[displayID] = reported
            safeAreaTop = reported
        } else {
            safeAreaTop = safeAreaCache[displayID] ?? 0
        }
        return ScreenMetrics(
            displayID: displayID,
            // `frame`, NEVER `visibleFrame`: the latter subtracts the menu bar,
            // which is precisely the band we draw in.
            frame: screen.frame,
            // Only the WIDTHS are consumed. The origins of these two rects
            // behave inconsistently across mirrored and rearranged displays; a
            // width is invariant under any coordinate-space confusion.
            auxLeftWidth: screen.auxiliaryTopLeftArea?.width ?? 0,
            auxRightWidth: screen.auxiliaryTopRightArea?.width ?? 0,
            safeAreaTop: safeAreaTop
        )
    }

    static func displayID(of screen: NSScreen) -> UInt32 {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
            .uint32Value ?? 0
    }
}

// MARK: - Live invariant

extension NotchGeometryResolver {

    /// Assert the invariant against a real, resolved geometry and LOG rather
    /// than trap.
    ///
    /// A violation on a display arrangement nobody has ever tried must degrade
    /// to a slightly wrong pill, not to a crash in an app that is supposed to
    /// run for weeks. The log line is what turns "the pill looks odd on my
    /// ultrawide" into a bug report with numbers in it.
    @discardableResult
    static func assertInvariant(_ geometry: NotchGeometry) -> Bool {
        let report = check(geometry)
        guard !report.isSatisfied else { return true }
        for violation in report.violations {
            uiLog.error("notch geometry invariant violated: \(violation, privacy: .public)")
        }
        uiLog.error("resolved geometry was:\n\(geometry.description, privacy: .public)")
        return false
    }
}
