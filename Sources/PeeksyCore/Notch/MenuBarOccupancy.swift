import CoreGraphics
import Foundation

// Where the OTHER apps' menu bar status items actually are.
//
// The pure half. `Sources/Peeksy/Notch/MenuBarScanner.swift` is the shell
// that calls `CGWindowListCopyWindowInfo` and hands the result here, so every
// filter, every coordinate flip and every trust rule below is testable against
// synthetic window lists rather than against whatever happens to be in the menu
// bar of the machine running the tests.
//
// We do this at all because there is no API for it. `NSStatusItem.isVisible`
// returns true even when the item is hidden behind the notch, and nothing tells
// an app how much of the bar is spoken for. The window list is the only route,
// and it needs no TCC grant as long as `kCGWindowName` is left alone.

// MARK: - Input

/// One on-screen window, reduced to the four keys we are willing to read.
///
/// There is deliberately no owner-name and no owner-pid field. On macOS 26
/// (FB18327911) BOTH report Control Center for every status item — including
/// this app's own — so any code that reached for them would be quietly wrong.
/// Making them unrepresentable is a stronger guarantee than a comment saying
/// "don't".
///
/// `kCGWindowName` is excluded for a different reason: it is gated behind the
/// Screen Recording grant, and the permission surface for this app is
/// Automation→Terminal and nothing else.
public struct StatusWindow: Sendable, Equatable {
    /// `kCGWindowNumber`. The same value as `NSWindow.windowNumber`, and
    /// therefore the only identity of ours that survives macOS 26.
    public let windowID: UInt32
    /// `kCGWindowLayer`.
    public let layer: Int
    /// EXACTLY `kCGWindowBounds`: TOP-LEFT origin, y increasing DOWNWARD, in the
    /// global display space. Named `cgBounds` rather than `frame` so nobody
    /// compares it with an AppKit rect by accident.
    public let cgBounds: CGRect
    /// `kCGWindowAlpha`.
    public let alpha: Double

    public init(windowID: UInt32, layer: Int, cgBounds: CGRect, alpha: Double = 1) {
        self.windowID = windowID
        self.layer = layer
        self.cgBounds = cgBounds
        self.alpha = alpha
    }
}

// MARK: - Result

/// Whether a sample may be acted on.
///
/// Every consumer must treat `.untrusted` as "hold whatever you are doing" —
/// never as "there is nothing there". A sample that failed its self-checks and a
/// genuinely empty menu bar look identical from the outside and mean opposite
/// things.
public enum MenuBarTrust: Sendable, Equatable {
    case trusted
    case untrusted(reason: String)

    public var isTrusted: Bool { self == .trusted }
}

public struct MenuBarOccupancy: Sendable, Equatable {
    public let displayID: UInt32
    /// Leftmost edge of the right-aligned status item run, in AppKit global
    /// coordinates (y-up), or nil when nothing was found.
    public let statusRunMinX: CGFloat?
    /// Every surviving item, left to right, AppKit global. Diagnostics and the
    /// tiling check.
    public let items: [CGRect]
    public let trust: MenuBarTrust

    public init(displayID: UInt32, statusRunMinX: CGFloat?, items: [CGRect], trust: MenuBarTrust) {
        self.displayID = displayID
        self.statusRunMinX = statusRunMinX
        self.items = items
        self.trust = trust
    }

    /// Clear air between our right edge and the first status item, or nil when
    /// there is nothing to measure against.
    public func clearance(rightOf maxX: CGFloat) -> CGFloat? {
        statusRunMinX.map { $0 - maxX }
    }
}

// MARK: - Derivation

public enum MenuBarScan {

    /// `kCGStatusWindowLevel` — the layer menu bar status items live on.
    ///
    /// A DEFAULT rather than a constant: the scanner overrides it with the layer
    /// it observes on a status item it knows about, so the filter self-calibrates
    /// if Apple ever moves them.
    public static let defaultStatusLayer = 25

    /// Vertical slack on the band filter.
    ///
    /// The menu bar's own CG window measures 33 pt on a notched panel whose
    /// `safeAreaTop` is 32, and status items match it rather than the band. 6 pt
    /// covers that and the non-notch case without being wide enough to admit a
    /// dropped-down menu.
    public static let bandSlack: CGFloat = 6

    /// Widest a single status item may be, as a fraction of the screen. Guards
    /// against a full-width layer-25 window poisoning the minimum.
    public static let maxItemWidthFraction: CGFloat = 0.5

    /// Largest gap tolerated between adjacent items before the run stops looking
    /// like a run.
    public static let tilingSlack: CGFloat = 2
    /// How far short of the screen's right edge the run may end.
    public static let runEndSlack: CGFloat = 8
    /// How far a calibration rect may disagree before the sample is distrusted.
    public static let calibrationSlack: CGFloat = 2

    /// `kCGMainMenuWindowLevel` — the layer the menu bar itself is drawn on, one
    /// below the status items that sit in it.
    public static let defaultMenuBarLayer = 24

    /// How much of a display's width the menu bar window must span to be the
    /// menu bar rather than something else that happens to share its layer.
    public static let menuBarWidthFraction: CGFloat = 0.9

    /// Is there a menu bar on this display right now?
    ///
    /// Replaces asking a status item of our own, which cost the user ~17 pt of
    /// menu bar to answer and — being the leftmost item on a full bar — was the
    /// first thing macOS dropped, at which point the app hid itself for good.
    ///
    /// Returns the menu bar's rect in AppKit global coordinates, or nil.
    ///
    /// The band-overlap requirement is what catches an AUTO-HIDDEN menu bar:
    /// macOS parks that window above the screen's top edge rather than removing
    /// it, so it is still "on screen" and still full width. Requiring it to
    /// actually overlap the display's band is the same trick the status-item
    /// anchor used, without the status item.
    public static func menuBarWindow(
        in screen: ScreenMetrics,
        bandHeight: CGFloat,
        windows: [StatusWindow],
        primaryScreenMaxY: CGFloat,
        menuBarLayer: Int = defaultMenuBarLayer
    ) -> CGRect? {
        let f = screen.frame
        let band = CGRect(
            x: f.minX,
            y: f.maxY - bandHeight,
            width: f.width,
            height: bandHeight)

        for window in windows where window.layer == menuBarLayer {
            let rect = appKitRect(fromCGWindowBounds: window.cgBounds,
                                  primaryScreenMaxY: primaryScreenMaxY)
            let wideEnough: Bool = rect.width >= f.width * menuBarWidthFraction
            let onThisDisplay: Bool = rect.midX >= f.minX && rect.midX <= f.maxX
            let inTheBand: Bool = rect.intersects(band)
            if wideEnough && onThisDisplay && inTheBand { return rect }
        }
        return nil
    }

    /// `kCGWindowBounds` (top-left origin, y DOWN) → AppKit global (bottom-left
    /// origin, y UP).
    ///
    ///     y = primaryScreenMaxY - (cg.origin.y + cg.size.height)
    ///
    /// NOT `- cg.origin.y`. That is off by the rect's FULL HEIGHT — 33 pt on a
    /// 32 pt band — so every status item lands one band BELOW the menu bar, the
    /// band filter returns nothing, and an empty result reads as "the bar is
    /// empty", i.e. we would never yield to anybody. It is the same
    /// full-rect-height error `NotchGeometryResolver.swiftUIRect` calls out by
    /// name, and it looks just as plausible.
    ///
    /// `x` is identical in both spaces. `primaryScreenMaxY` is the height of the
    /// display whose frame origin is (0,0): CG's global origin is that display's
    /// TOP-left and AppKit's is its BOTTOM-left, so the two spaces differ by
    /// exactly its height. A display positioned ABOVE the primary has a negative
    /// `cg.y` and correctly converts to an AppKit `y` greater than
    /// `primaryScreenMaxY`.
    public static func appKitRect(
        fromCGWindowBounds cg: CGRect,
        primaryScreenMaxY: CGFloat
    ) -> CGRect {
        CGRect(
            x: cg.origin.x,
            y: primaryScreenMaxY - (cg.origin.y + cg.size.height),
            width: cg.size.width,
            height: cg.size.height
        )
    }

    /// Filter a raw window list down to the status items sitting in one display's
    /// menu bar, and judge whether the answer can be believed.
    ///
    /// `calibration` is a window whose true AppKit frame the caller already knows
    /// — in practice our own panel. If it appears in `windows`, its converted
    /// bounds must agree, which is a live ground-truth check on both the bounds
    /// and the conversion above, for free, on every sample and every macOS
    /// version.
    public static func occupancy(
        windows: [StatusWindow],
        screen: ScreenMetrics,
        bandHeight: CGFloat,
        primaryScreenMaxY: CGFloat,
        statusLayer: Int = defaultStatusLayer,
        calibration: (windowID: UInt32, appKitFrame: CGRect)? = nil
    ) -> MenuBarOccupancy {
        let f = screen.frame
        let eps = NotchGeometryResolver.epsilon

        func result(_ items: [CGRect], _ trust: MenuBarTrust) -> MenuBarOccupancy {
            MenuBarOccupancy(
                displayID: screen.displayID,
                statusRunMinX: items.map(\.minX).min(),
                items: items,
                trust: trust)
        }

        // Calibration first: if the conversion is wrong, every number below is
        // wrong in the same direction and would look perfectly reasonable.
        if let calibration {
            if let mine = windows.first(where: { $0.windowID == calibration.windowID }) {
                let converted = appKitRect(fromCGWindowBounds: mine.cgBounds,
                                           primaryScreenMaxY: primaryScreenMaxY)
                let dx = abs(converted.minX - calibration.appKitFrame.minX)
                let dw = abs(converted.width - calibration.appKitFrame.width)
                if dx > calibrationSlack || dw > calibrationSlack {
                    return result([], .untrusted(
                        reason: "calibration window \(calibration.windowID) converted to \(converted), expected \(calibration.appKitFrame)"))
                }
            }
            // Absent is not a failure. Our own panel is legitimately off-screen
            // while ordered out, and a window that is not in the list cannot
            // disagree with anything.
        }

        // The band, in AppKit global coordinates, slackened on BOTH edges.
        //
        // Downward for the obvious reason: the menu bar's own window is 33 pt on
        // a panel whose `safeAreaTop` is 32, and status items match the window
        // rather than the band. Upward because status items were measured
        // transiently reporting `y = -3` in CG space — three points ABOVE the
        // physical screen top — while the steady state is `y = 0`. Without the
        // upper slack that transient rejects every item at once, which reads as
        // "the menu bar is empty" and is the most dangerous thing this file
        // could get wrong.
        let band = CGRect(
            x: f.minX,
            y: f.maxY - (bandHeight + bandSlack),
            width: f.width,
            height: bandHeight + 2 * bandSlack)

        // CONTAINMENT, not intersection. In one predicate this rejects items
        // belonging to another display AND anything taller than the band — an
        // open status menu hanging down over the desktop is a layer-25 window
        // too, and letting one in would drag `statusRunMinX` hundreds of points
        // left and make us yield to a menu that is about to close.
        //
        // Spelled out rather than written as one `&&` chain: four CGFloat
        // comparisons joined by `&&` inside a closure is enough to make the
        // Swift type-checker give up ("unable to type-check this expression in
        // reasonable time").
        func sitsInBand(_ rect: CGRect) -> Bool {
            // Horizontally the MIDPOINT decides, not containment. Measured: the
            // rightmost item (the clock, 137 pt wide) reports bounds ending at
            // 1514 on a 1512 pt display — status items are allowed to overhang
            // the screen edge, and requiring containment silently dropped it,
            // which then failed the run-end check and distrusted every sample.
            // A midpoint still attributes an item to the right display, which is
            // all this test is for.
            let notLeftOfDisplay: Bool = rect.midX >= f.minX
            let notRightOfDisplay: Bool = rect.midX <= f.maxX
            // Vertically it IS containment, because that is what rejects an open
            // status menu hanging down over the desktop.
            let bottomOK: Bool = rect.minY >= band.minY - eps
            let topOK: Bool = rect.maxY <= band.maxY + eps
            return notLeftOfDisplay && notRightOfDisplay && bottomOK && topOK
        }

        func isPlausibleItem(_ rect: CGRect) -> Bool {
            let hasWidth: Bool = rect.width > 0
            let notTheWholeBar: Bool = rect.width <= f.width * maxItemWidthFraction
            return hasWidth && notTheWholeBar
        }

        let atLayer = windows.filter { $0.layer == statusLayer && $0.alpha > 0.01 }
        let converted = atLayer.map {
            appKitRect(fromCGWindowBounds: $0.cgBounds, primaryScreenMaxY: primaryScreenMaxY)
        }
        let items = converted
            .filter(sitsInBand)
            .filter(isPlausibleItem)
            .sorted { $0.minX < $1.minX }

        guard !items.isEmpty else {
            return result([], .untrusted(reason: "no status windows at layer \(statusLayer)"))
        }

        // Tiling. macOS packs status items against the right edge with no gaps,
        // so a contiguous run ending at the screen edge is a strong signature
        // that these bounds mean what we think they mean. If Apple ever returns
        // stale or transformed rects, this is what notices.
        for (prev, next) in zip(items, items.dropFirst()) {
            let gap = abs(next.minX - prev.maxX)
            if gap > tilingSlack {
                return result(items, .untrusted(
                    reason: "status items do not tile: \(gap) pt gap at x=\(prev.maxX)"))
            }
        }
        if let last = items.last, f.maxX - last.maxX > runEndSlack {
            return result(items, .untrusted(
                reason: "status run ends at \(last.maxX), \(f.maxX - last.maxX) pt short of the screen edge"))
        }

        return result(items, .trusted)
    }
}
