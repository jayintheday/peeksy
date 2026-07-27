import CoreGraphics
import Foundation

// The pure half of the notch window's geometry.
//
// Nothing in this file imports AppKit. `Sources/AgentNotch/Notch/NotchGeometry.swift`
// is the thin shell that turns an `NSScreen` into `ScreenMetrics` and hands the
// answer back to `NotchController`; every number below is derived here so it can
// be tested against synthetic displays instead of against whatever Mac happens
// to be running the tests.
//
// Portions adapted from open-focus (MIT, © 2026 Filip Sokolowski) — see NOTICE.
// Specifically the `auxiliaryTopLeftArea`/`auxiliaryTopRightArea` width trick for
// recovering the notch width, which is the only supported way to get it.

// MARK: - Phase

/// The three states the window can be in. Shared by the geometry, the hover FSM
/// and the controller so there is exactly one vocabulary.
public enum NotchPhase: String, Sendable, CaseIterable {
    /// Pill only. The window is the size of the pill (plus the notch it paints over).
    case collapsed
    /// Open because the cursor is dwelling. Hover-exit closes it.
    case peeking
    /// Open because the user clicked. Only an explicit dismissal closes it.
    case pinned

    public var isOpen: Bool { self != .collapsed }
}

// MARK: - Screen input

/// Everything the maths needs to know about one display.
///
/// Deliberately a value type with no `NSScreen` inside: the resolver must be
/// runnable against a synthetic 16" panel, a non-notch external, and a
/// negative-origin secondary in a unit test.
public struct ScreenMetrics: Sendable, Equatable {
    public let displayID: UInt32
    /// `NSScreen.frame` — global, y-up, INCLUDING the menu bar strip.
    ///
    /// NEVER `visibleFrame`. `visibleFrame` subtracts the menu bar, which is
    /// precisely the band we need to draw in.
    public let frame: CGRect
    /// `NSScreen.auxiliaryTopLeftArea?.width ?? 0`.
    ///
    /// Only the WIDTH is consumed, never the origin: the origins of these two
    /// rects behave inconsistently across mirrored and rearranged displays,
    /// whereas a width is invariant under any coordinate-space confusion.
    public let auxLeftWidth: CGFloat
    public let auxRightWidth: CGFloat
    /// `NSScreen.safeAreaInsets.top`, already repaired by the caller's per-display
    /// cache — it transiently reports 0 on a notched panel (observed during
    /// wake and display reconfiguration).
    public let safeAreaTop: CGFloat

    public init(
        displayID: UInt32,
        frame: CGRect,
        auxLeftWidth: CGFloat,
        auxRightWidth: CGFloat,
        safeAreaTop: CGFloat
    ) {
        self.displayID = displayID
        self.frame = frame
        self.auxLeftWidth = auxLeftWidth
        self.auxRightWidth = auxRightWidth
        self.safeAreaTop = safeAreaTop
    }

    /// Width of the hardware notch, as the gap the two auxiliary areas leave.
    public var notchWidth: CGFloat {
        max(0, frame.width - auxLeftWidth - auxRightWidth)
    }

    /// All four conditions matter. A non-notch external reports both auxiliary
    /// areas as nil (⇒ 0), which would otherwise make `notchWidth` the entire
    /// screen width.
    public var hasNotch: Bool {
        auxLeftWidth > 0 && auxRightWidth > 0 && notchWidth > 1 && safeAreaTop > 0
    }
}

// MARK: - Tunables

/// Hand-tunable constants. Separated from the derivation so the invariant below
/// keeps working when someone changes a number.
public struct NotchLayout: Sendable, Equatable {
    /// Slack between the DRAWN capsule and the layout slot the window reserves
    /// for it.
    ///
    /// Zero, and that is a position rather than a placeholder: the slot is menu
    /// bar the window paints opaque black, so every point of padding is a point
    /// of somebody else's status icon covered — and, because
    /// `FirstMouseHostingView.hitTest` returns nil rather than forwarding,
    /// un-clickable too. `PillMetrics` is the single source for how wide the
    /// capsule really is, and `check` asserts the slot has not drifted from it.
    public var pillPadding: CGFloat
    /// Gap between the notch's right edge and the pill slot. Also the reason
    /// `pillRect` never intersects `notchRect`, which the invariant asserts.
    public var pillGap: CGFloat
    /// Hover slop on the NOTCH side of the pill.
    ///
    /// FREE, up to `pillGap`: it lands in the notch band the collapsed window
    /// already occupies, so widening the hover target on this side costs no menu
    /// bar pixels at all. That asymmetry with `hoverSlopTrailing` is the whole
    /// trick, and `check` asserts the leading edge really does stop at the notch.
    public var hoverSlopLeading: CGFloat
    /// Hover slop on the far side of the pill — the ONLY slop that is paid for
    /// in the user's menu bar, because it is the edge facing the right-aligned
    /// status item run. Kept small on purpose.
    ///
    /// Vertical slop, on both sides, is deliberately ZERO: the collapsed window
    /// is the union of the notch and this rect, so a vertical expansion would
    /// push the window below the menu bar and create exactly the dead zone this
    /// design exists to avoid.
    public var hoverSlopTrailing: CGFloat
    /// Preferred expanded width. Reduced, never exceeded, if the screen is too
    /// narrow to the right of the notch.
    public var preferredPanelWidth: CGFloat
    /// Width of a small decorative cap painted immediately left of the notch,
    /// purely so the shape has a corner to round in real screen pixels
    /// instead of under the camera housing. No UI lives in it. Clamped to
    /// whatever room exists before the screen edge — see `leftCapRect`.
    ///
    /// ZERO by default. M3a bought that rounded corner for `leftCapWidth +
    /// pillGap` points of the strip macOS reserves for the frontmost app's own
    /// menus, and a menu is worse to occlude than an icon — the same clicks are
    /// swallowed either way. Kept as a constructor argument, not deleted, so the
    /// invariant keeps naming `leftCapRect` and the flourish is one number away.
    public var leftCapWidth: CGFloat
    /// Band height used when there is no hardware notch.
    public var fallbackBandHeight: CGFloat
    /// Ceiling on the list, as a fraction of screen height.
    public var maxListFraction: CGFloat
    /// How far outside the expanded frame the cursor may stray while `.peeking`
    /// without starting the exit grace.
    public var corridorSlop: CGFloat

    public init(
        pillPadding: CGFloat = 0,
        pillGap: CGFloat = 6,
        hoverSlopLeading: CGFloat = 6,
        hoverSlopTrailing: CGFloat = 2,
        preferredPanelWidth: CGFloat = 380,
        leftCapWidth: CGFloat = 0,
        fallbackBandHeight: CGFloat = 26,
        maxListFraction: CGFloat = 0.6,
        corridorSlop: CGFloat = 14
    ) {
        self.pillPadding = pillPadding
        self.pillGap = pillGap
        self.hoverSlopLeading = hoverSlopLeading
        self.hoverSlopTrailing = hoverSlopTrailing
        self.preferredPanelWidth = preferredPanelWidth
        self.leftCapWidth = leftCapWidth
        self.fallbackBandHeight = fallbackBandHeight
        self.maxListFraction = maxListFraction
        self.corridorSlop = corridorSlop
    }

    public static let `default` = NotchLayout()
}

// MARK: - Result

/// Every rect the window layer needs, in ONE coordinate space: AppKit global,
/// y-up, origin at the bottom-left of the primary display.
///
/// `HoverEngine` and `DismissMonitor` work exclusively here — `NSEvent.mouseLocation`
/// is already in this space, so there is no conversion and therefore no
/// conversion bug. The two conversions that do exist (`windowRect`,
/// `swiftUIRect`) are static functions at the bottom of this file and are unit
/// tested, because writing `maxY - minY` where `maxY - maxY` belongs is a
/// full-rect-height error that looks entirely plausible on a notched Mac.
public struct NotchGeometry: Sendable, Equatable {
    public let displayID: UInt32
    public let screenFrame: CGRect
    public let hasNotch: Bool
    /// Height of the top band. Equals the notch height on a notched display.
    /// NEVER animates — the notch must not appear to move.
    public let bandHeight: CGFloat
    /// The hardware notch, or a degenerate zero-width rect pinned at
    /// `pillHotRect.minX` when there is none.
    public let notchRect: CGRect
    /// The pill's layout slot: full band height, top pinned to the screen top.
    /// The capsule is centred inside it by the view.
    public let pillRect: CGRect
    /// The rect the capsule is actually PAINTED in — `pillRect` less
    /// `pillPadding`, and the same thing at the default padding of zero.
    ///
    /// Carried separately so the footprint is checkable: `check` refuses a
    /// collapsed window that reserves meaningfully more menu bar than this.
    public let pillContentRect: CGRect
    /// `pillRect` widened by the two hover slops. Same height, same top edge.
    public let pillHotRect: CGRect
    /// A small decorative strip immediately left of `notchRect`, or a
    /// degenerate zero-width rect pinned at `notchRect.minX` when there is
    /// no room for it or no notch. Never in `interactiveRects` — it exists
    /// only so `NotchChrome` has real screen pixels to round the shape's
    /// bottom-left corner into, mirroring the pill's rounded end on the
    /// right, even though nothing is clickable here.
    public let leftCapRect: CGRect
    /// THE INVARIANT, as a definition rather than a defence:
    /// `collapsedFrame == notchRect ∪ pillHotRect ∪ leftCapRect`.
    ///
    /// The window is only ever as large as the thing it draws, so a transparent
    /// region that swallows clicks meant for other apps cannot exist.
    public let collapsedFrame: CGRect
    public let expandedFrame: CGRect
    /// Height of the animating list container. `expandedFrame.height - bandHeight`.
    public let listHeight: CGFloat
    /// Used ONLY while `.peeking`, and computed from the FINAL expanded frame so
    /// a fast downward flick counts as "inside" before the window has grown.
    public let graceCorridor: CGRect
    /// Full-width menu bar strip. A cursor that leaves us into this strip is
    /// heading for Control Center and gets the short grace.
    public let menuBarStrip: CGRect

    /// The clickable part of the expanded panel, global. Empty when collapsed
    /// content would make it zero-height.
    public var listRect: CGRect {
        CGRect(
            x: expandedFrame.minX,
            y: expandedFrame.minY,
            width: expandedFrame.width,
            height: max(0, expandedFrame.height - bandHeight)
        )
    }

    /// Frame the window should have in a given phase.
    public func frame(for phase: NotchPhase) -> CGRect {
        phase == .collapsed ? collapsedFrame : expandedFrame
    }

    /// The interactive mask, in GLOBAL coordinates, for a given phase.
    ///
    /// The notch x-range is absent from every case on purpose. We paint opaque
    /// black across it so the hardware's rounded corners reveal our black rather
    /// than the wallpaper, which means clicks land on us whether we want them or
    /// not; the only safe thing to do with a click the user cannot see the
    /// target of is nothing. Consequence for layout: no interactive chrome may
    /// sit in the band's notch x-range.
    public func interactiveRects(for phase: NotchPhase) -> [CGRect] {
        switch phase {
        case .collapsed:
            return [pillRect]
        case .peeking, .pinned:
            let list = listRect
            return list.isEmpty ? [pillRect] : [pillRect, list]
        }
    }

    /// Hover zones for `HoverEngineCore`, all global.
    public var hoverZones: HoverZones {
        HoverZones(
            pillHot: pillHotRect,
            panel: expandedFrame,
            graceCorridor: graceCorridor,
            menuBarStrip: menuBarStrip
        )
    }
}

// MARK: - Derivation

public enum NotchGeometryResolver {

    /// Derive every rect from `screen.frame` and two widths.
    ///
    /// `listContentHeight` is the height the expanded list WANTS. The window is a
    /// step function around the animation, so this has to be known before the
    /// window grows; the view layer pins its row heights to make the estimate
    /// exact rather than approximate.
    ///
    /// `pillContentWidth` is the same idea for the collapsed width: the capsule
    /// is narrower with no sessions than with some, and the window must reserve
    /// the smaller footprint in that case rather than sit on menu bar it is not
    /// using. Comes from `PillMetrics.contentWidth(sessionCount:)`.
    public static func resolve(
        screen: ScreenMetrics,
        listContentHeight: CGFloat,
        pillContentWidth: CGFloat = PillMetrics.contentWidth(sessionCount: 1),
        layout: NotchLayout = .default
    ) -> NotchGeometry {
        let f = screen.frame
        let hasNotch = screen.hasNotch
        let bandHeight = hasNotch ? screen.safeAreaTop : layout.fallbackBandHeight
        let bandY = f.maxY - bandHeight

        // The notch, when there is one. Built from `frame` plus the left
        // auxiliary WIDTH — never from `auxiliaryTopLeftArea.origin`.
        let notchW = hasNotch ? screen.notchWidth : 0
        let notchX = hasNotch ? f.minX + screen.auxLeftWidth : 0

        // Pill placement. On a notched display it sits immediately right of the
        // notch: the frontmost app's menus are always LEFT of the notch and
        // status items are right-aligned, so the first few points to the right
        // of the notch are the emptiest real estate in the menu bar.
        // The slot is the drawn capsule plus padding, NOT a fixed constant. The
        // window paints this rect opaque black over the menu bar, so a slot
        // wider than its content is menu bar taken from other apps to show
        // nothing.
        let pillW = min(pillContentWidth + 2 * layout.pillPadding, f.width)
        var pillX: CGFloat
        if hasNotch {
            pillX = notchX + notchW + layout.pillGap
        } else {
            // No notch: hang the tab from the middle of the top edge, which is
            // the same place the notch would have been.
            pillX = f.midX - pillW / 2
        }
        pillX = min(pillX, f.maxX - pillW - layout.hoverSlopTrailing)
        pillX = max(pillX, f.minX + layout.hoverSlopLeading)
        let pillRect = CGRect(x: pillX, y: bandY, width: pillW, height: bandHeight)
        let pillContentRect = pillRect.insetBy(dx: layout.pillPadding, dy: 0)

        var hotX = pillRect.minX - layout.hoverSlopLeading
        var hotMaxX = pillRect.maxX + layout.hoverSlopTrailing
        hotX = max(hotX, f.minX)
        hotMaxX = min(hotMaxX, f.maxX)
        // Slop is horizontal only. A vertical expansion would drag the collapsed
        // window below the menu bar and manufacture a dead zone.
        let pillHotRect = CGRect(x: hotX, y: bandY, width: hotMaxX - hotX, height: bandHeight)

        // Degenerate notch pinned at the pill's left edge, so `panelX ==
        // pillHot.minX`, the union below collapses to the pill, and the SAME
        // view hierarchy renders as a black tab hanging from the screen top.
        // One shape, no branch in the view layer.
        let notchRect = hasNotch
            ? CGRect(x: notchX, y: bandY, width: notchW, height: bandHeight)
            : CGRect(x: pillHotRect.minX, y: bandY, width: 0, height: bandHeight)

        // Mirrors the pill's gap-then-rounded-end on the OTHER side of the
        // notch, but with no content: purely so the shape has a corner to
        // round in real screen pixels. Degenerate (zero width, pinned at
        // `notchRect.minX`, same trick as `notchRect` above) when there's no
        // notch or no room before the screen edge — never lets the window
        // grow into negative room.
        let leftCapRoom = max(0, notchRect.minX - f.minX - layout.pillGap)
        let leftCapW = hasNotch ? min(layout.leftCapWidth, leftCapRoom) : 0
        let leftCapX = leftCapW > 0 ? notchRect.minX - layout.pillGap - leftCapW : notchRect.minX
        let leftCapRect = CGRect(x: leftCapX, y: bandY, width: leftCapW, height: bandHeight)

        // `CGRect.union` returns the non-empty operand when one side is empty,
        // which is exactly the non-notch behaviour we want.
        let collapsedFrame = notchRect.union(pillHotRect).union(leftCapRect)

        // Expanded. The top-left origin is IDENTICAL to the collapsed frame's,
        // which is what lets the SwiftUI content sit in a `.topLeading` frame
        // and animate its own size without the window origin ever moving.
        let room = f.maxX - collapsedFrame.minX
        var expandedWidth = min(layout.preferredPanelWidth, room)
        expandedWidth = max(expandedWidth, collapsedFrame.width)

        let listCeiling = max(0, f.height * layout.maxListFraction)
        let listHeight = min(max(0, listContentHeight), listCeiling)
        let expandedHeight = bandHeight + listHeight
        let expandedFrame = CGRect(
            x: collapsedFrame.minX,
            y: f.maxY - expandedHeight,
            width: expandedWidth,
            height: expandedHeight
        )

        let corridor = expandedFrame
            .insetBy(dx: -layout.corridorSlop, dy: -layout.corridorSlop)
            .intersection(f)
            .union(pillHotRect)

        return NotchGeometry(
            displayID: screen.displayID,
            screenFrame: f,
            hasNotch: hasNotch,
            bandHeight: bandHeight,
            notchRect: notchRect,
            pillRect: pillRect,
            pillContentRect: pillContentRect,
            pillHotRect: pillHotRect,
            leftCapRect: leftCapRect,
            collapsedFrame: collapsedFrame,
            expandedFrame: expandedFrame,
            listHeight: listHeight,
            graceCorridor: corridor,
            menuBarStrip: CGRect(x: f.minX, y: bandY, width: f.width, height: bandHeight)
        )
    }
}

// MARK: - Invariant

/// Result of the live invariant check. Reported rather than trapped: a geometry
/// violation on a display we have never seen must degrade to a slightly wrong
/// pill, not to a crash in a 24/7 menu-bar app.
public struct GeometryInvariantReport: Sendable, Equatable {
    public let violations: [String]
    public var isSatisfied: Bool { violations.isEmpty }

    public init(violations: [String]) { self.violations = violations }
}

extension NotchGeometryResolver {

    /// Tolerance in points. Rects come out of `NSScreen` on half-point
    /// boundaries on Retina panels.
    public static let epsilon: CGFloat = 0.01

    /// How much menu bar the collapsed window may reserve to the RIGHT of the
    /// drawn capsule.
    ///
    /// This is the number the occlusion bug was made of: the window used to end
    /// 10 pt past the capsule with a fixed 52 pt slot inside a 64 pt hot rect,
    /// all of it opaque black over the right-aligned status item run. Asserting a
    /// ceiling makes the footprint a structural property instead of a tuning that
    /// drifts back.
    public static let maxTrailingWaste: CGFloat = 8

    /// `collapsedFrame ⊆ (notchRect ∪ pillHotRect ∪ leftCapRect)` — asserted
    /// live on every geometry change.
    ///
    /// The containment is trivially true because `collapsedFrame` is DERIVED as
    /// that union. That is the point: zero dead zone is structural. The rest of
    /// the checks are regression guards for whoever later hand-tunes
    /// `NotchLayout` and accidentally makes the window taller than the menu bar
    /// or wider than the shape it draws.
    public static func check(_ g: NotchGeometry) -> GeometryInvariantReport {
        var bad: [String] = []
        let eps = epsilon

        func eq(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) <= eps }
        func eq(_ a: CGRect, _ b: CGRect) -> Bool {
            eq(a.minX, b.minX) && eq(a.minY, b.minY) && eq(a.width, b.width) && eq(a.height, b.height)
        }
        /// `outer` contains `inner`, within epsilon.
        func contains(_ outer: CGRect, _ inner: CGRect) -> Bool {
            inner.minX >= outer.minX - eps && inner.maxX <= outer.maxX + eps
                && inner.minY >= outer.minY - eps && inner.maxY <= outer.maxY + eps
        }

        let union = g.notchRect.union(g.pillHotRect).union(g.leftCapRect)
        if !eq(g.collapsedFrame, union) {
            bad.append("collapsedFrame \(g.collapsedFrame) != notchRect ∪ pillHotRect ∪ leftCapRect \(union)")
        }
        if !contains(union, g.collapsedFrame) {
            bad.append("collapsedFrame escapes notchRect ∪ pillHotRect ∪ leftCapRect")
        }
        if !contains(g.screenFrame, g.collapsedFrame) {
            bad.append("collapsedFrame \(g.collapsedFrame) escapes screenFrame \(g.screenFrame)")
        }
        if !contains(g.screenFrame, g.expandedFrame) {
            bad.append("expandedFrame \(g.expandedFrame) escapes screenFrame \(g.screenFrame)")
        }
        if !contains(g.expandedFrame, g.collapsedFrame) {
            bad.append("expandedFrame does not contain collapsedFrame — the window would shrink to open")
        }
        // The whole animation design rests on the window's top-left staying put.
        if !eq(g.expandedFrame.minX, g.collapsedFrame.minX) {
            bad.append("expandedFrame.minX \(g.expandedFrame.minX) != collapsedFrame.minX \(g.collapsedFrame.minX)")
        }
        if !eq(g.collapsedFrame.maxY, g.screenFrame.maxY) {
            bad.append("collapsedFrame is not flush with the screen top")
        }
        if !eq(g.expandedFrame.maxY, g.screenFrame.maxY) {
            bad.append("expandedFrame is not flush with the screen top")
        }
        // The assertion the design calls out by name: panel top == pill top, so
        // the y-down conversion of the pill has a zero origin.
        if !eq(g.pillRect.maxY, g.screenFrame.maxY) {
            bad.append("pillRect.maxY \(g.pillRect.maxY) != screenFrame.maxY \(g.screenFrame.maxY)")
        }
        if !eq(g.collapsedFrame.height, g.bandHeight) {
            bad.append("collapsedFrame.height \(g.collapsedFrame.height) != bandHeight \(g.bandHeight)")
        }
        // THE FOOTPRINT GUARDS. Everything above bounds the window to the shape
        // it draws; these two bound the shape itself, because a shape wider than
        // its content is still menu bar taken from other apps.
        if !contains(g.pillRect, g.pillContentRect) {
            bad.append("pillRect \(g.pillRect) does not contain pillContentRect \(g.pillContentRect) — the window reserves less than the pill paints")
        }
        let trailingWaste = g.collapsedFrame.maxX - g.pillContentRect.maxX
        if trailingWaste > maxTrailingWaste + eps {
            bad.append("the collapsed window reserves \(trailingWaste) pt of menu bar right of the drawn pill (max \(maxTrailingWaste))")
        }
        if g.hasNotch {
            if g.notchRect.width <= 1 {
                bad.append("hasNotch but notchRect.width == \(g.notchRect.width)")
            }
            // Leading hover slop is free only while it stays inside the notch
            // band the window already owns. Past that it starts costing the
            // frontmost app's menu strip, silently.
            if g.pillHotRect.minX < g.notchRect.maxX - eps {
                bad.append("pillHotRect.minX \(g.pillHotRect.minX) reaches left of notchRect.maxX \(g.notchRect.maxX) — leading slop is no longer free")
            }
            // No interactive chrome in the notch x-range, enforced at the source.
            //
            // The `isEmpty` guards are LOAD-BEARING, not tidiness. Measured:
            // `CGRect.intersects` returns TRUE for a zero-width rect pinned
            // inside the other rect's x-range, even though that rect's own
            // `isEmpty` is true — so a degenerate `leftCapRect` at
            // `notchRect.minX` reads as an overlap. `union` disagrees and
            // ignores the same rect, which is why the collapsed frame is right
            // while the check was wrong.
            if !g.pillRect.isEmpty, g.notchRect.intersects(g.pillRect) {
                bad.append("pillRect intersects notchRect — an invisible click target")
            }
            if !g.leftCapRect.isEmpty, g.notchRect.intersects(g.leftCapRect) {
                bad.append("leftCapRect intersects notchRect")
            }
        } else {
            if g.notchRect.width != 0 {
                bad.append("no notch but notchRect.width == \(g.notchRect.width)")
            }
            if !eq(g.notchRect.minX, g.pillHotRect.minX) {
                bad.append("degenerate notchRect is not pinned at pillHotRect.minX")
            }
            if g.leftCapRect.width != 0 {
                bad.append("no notch but leftCapRect.width == \(g.leftCapRect.width)")
            }
        }
        return GeometryInvariantReport(violations: bad)
    }
}

// MARK: - Coordinate conversions

extension NotchGeometryResolver {

    /// Global (y-up) → window-local (y-up). Used for `interactiveMask`.
    public static func windowRect(_ global: CGRect, in windowFrame: CGRect) -> CGRect {
        global.offsetBy(dx: -windowFrame.minX, dy: -windowFrame.minY)
    }

    /// Global (y-up) → SwiftUI (y-down from the window's TOP edge).
    ///
    /// `windowFrame.maxY - global.maxY`, and NOT `- global.minY`. The wrong one
    /// is off by the rect's full height, which on a 32 pt band looks like a
    /// plausible padding mistake rather than a coordinate bug. Because the panel
    /// top and the pill top are both pinned to `screenFrame.maxY`, the pill's
    /// converted `y` is exactly 0 — see `NotchGeometryTests`.
    public static func swiftUIRect(_ global: CGRect, in windowFrame: CGRect) -> CGRect {
        CGRect(
            x: global.minX - windowFrame.minX,
            y: windowFrame.maxY - global.maxY,
            width: global.width,
            height: global.height
        )
    }
}

// MARK: - Debug

extension NotchGeometry: CustomStringConvertible {
    /// One field per line, so `--doctor` can print the numbers and a human can
    /// check the geometry without anybody taking a screenshot.
    public var description: String {
        func r(_ name: String, _ rect: CGRect) -> String {
            let f = { (v: CGFloat) in String(format: "%.1f", v) }
            return "  \(name.padding(toLength: 16, withPad: " ", startingAt: 0))"
                + "x=\(f(rect.minX)) y=\(f(rect.minY)) w=\(f(rect.width)) h=\(f(rect.height))"
        }
        return """
            display \(displayID)  hasNotch=\(hasNotch)  bandHeight=\(String(format: "%.1f", bandHeight))
            \(r("screenFrame", screenFrame))
            \(r("notchRect", notchRect))
            \(r("leftCapRect", leftCapRect))
            \(r("pillRect", pillRect))
            \(r("pillContentRect", pillContentRect))
            \(r("pillHotRect", pillHotRect))
            \(r("collapsedFrame", collapsedFrame))
            \(r("expandedFrame", expandedFrame))
            \(r("listRect", listRect))
            \(r("graceCorridor", graceCorridor))
            """
    }
}
