import CoreGraphics
import Foundation
import Testing

@testable import AgentNotchCore

// Synthetic displays. Every number is a real one read off hardware or off the
// arrangement panel, so a regression here means the maths changed rather than
// the fixture being unrealistic.
enum ScreenFixture {

    /// 14" MacBook Pro, the machine this milestone was built on.
    /// 1512×982, notch 185 pt wide, menu bar 32 pt.
    static let notched14 = ScreenMetrics(
        displayID: 1,
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        auxLeftWidth: 663,
        auxRightWidth: 664,
        safeAreaTop: 32
    )

    /// 16" MacBook Pro: 1728×1117, wider notch.
    static let notched16 = ScreenMetrics(
        displayID: 2,
        frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
        auxLeftWidth: 764,
        auxRightWidth: 764,
        safeAreaTop: 32
    )

    /// A plain external. Both auxiliary areas are nil on real hardware, which
    /// arrives here as 0 — the case that would otherwise make `notchWidth` the
    /// whole screen.
    static let external = ScreenMetrics(
        displayID: 3,
        frame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
        auxLeftWidth: 0,
        auxRightWidth: 0,
        safeAreaTop: 0
    )

    /// A secondary placed ABOVE and LEFT of the primary, so its origin is
    /// negative in both axes. This is the arrangement that breaks code which
    /// assumes rects start at zero.
    static let negativeOrigin = ScreenMetrics(
        displayID: 4,
        frame: CGRect(x: -1920, y: 982, width: 1920, height: 1080),
        auxLeftWidth: 0,
        auxRightWidth: 0,
        safeAreaTop: 0
    )

    /// A notched panel in the transient state where `safeAreaInsets.top` reports
    /// 0. The AppKit shell repairs this from its per-display cache; the pure
    /// side must degrade honestly rather than pretend.
    static let notchedWithZeroSafeArea = ScreenMetrics(
        displayID: 5,
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        auxLeftWidth: 663,
        auxRightWidth: 664,
        safeAreaTop: 0
    )

    static let all: [ScreenMetrics] = [notched14, notched16, external, negativeOrigin]
}

private let threeRows: CGFloat = 140

@Suite("NotchGeometry")
struct NotchGeometryTests {

    // MARK: - Detection

    @Test("a notch is only a notch when all four conditions hold")
    func notchDetection() {
        #expect(ScreenFixture.notched14.hasNotch)
        #expect(ScreenFixture.notched14.notchWidth == 185)
        #expect(ScreenFixture.notched16.hasNotch)
        #expect(ScreenFixture.notched16.notchWidth == 200)

        // An external reports zero for both auxiliary widths. Taking
        // `frame.width - 0 - 0` as the notch width would put a 2560 pt notch on
        // a display that has none.
        #expect(!ScreenFixture.external.hasNotch)
        #expect(!ScreenFixture.negativeOrigin.hasNotch)
        // A zero safe-area inset alone disqualifies it, even with both auxiliary
        // widths present.
        #expect(!ScreenFixture.notchedWithZeroSafeArea.hasNotch)
    }

    // MARK: - The invariant

    @Test("collapsedFrame ⊆ notchRect ∪ pillHotRect, on every fixture")
    func invariantHoldsEverywhere() {
        for screen in ScreenFixture.all {
            for content in [CGFloat(0), 40, threeRows, 4000] {
                // Both pill widths: the collapsed frame is content-driven now, so
                // an invariant that only held for one of them would hold for
                // roughly half the day.
                for sessions in [0, 3] {
                    let g = NotchGeometryResolver.resolve(
                        screen: screen,
                        listContentHeight: content,
                        pillContentWidth: PillMetrics.contentWidth(sessionCount: sessions))
                    let report = NotchGeometryResolver.check(g)
                    #expect(
                        report.isSatisfied,
                        "display \(screen.displayID) content \(content) sessions \(sessions): \(report.violations)")
                }
            }
        }
    }

    // MARK: - Menu bar footprint

    @Test("the pill's width is two-valued, so it cannot jitter as the count changes")
    func pillMetricsAreTwoValued() {
        #expect(PillMetrics.contentWidth(sessionCount: 0) == PillMetrics.capsuleHeight)
        for n in [1, 2, 9, 10, 99, 999] {
            #expect(PillMetrics.contentWidth(sessionCount: n) == PillMetrics.countedWidth)
        }
    }

    @Test("with no sessions the collapsed window gives the menu bar its pixels back")
    func collapsedShrinksWhenThereAreNoSessions() {
        let idle = resolveNotched14(sessions: 0)
        let busy = resolveNotched14(sessions: 3)
        // Exactly the difference between the drawn capsule and the drawn dot —
        // no slot padding hiding in between.
        #expect(busy.collapsedFrame.maxX - idle.collapsedFrame.maxX
            == PillMetrics.countedWidth - PillMetrics.capsuleHeight)
        #expect(idle.collapsedFrame.width < busy.collapsedFrame.width)
        #expect(NotchGeometryResolver.check(idle).isSatisfied)
        #expect(NotchGeometryResolver.check(busy).isSatisfied)
    }

    @Test("the drawn pill does not move sideways when the count changes")
    func theDrawnPillDoesNotMoveWhenTheCountChanges() {
        let idle = resolveNotched14(sessions: 0)
        let busy = resolveNotched14(sessions: 3)
        // It grows to the RIGHT, away from the notch. A capsule that slid
        // sideways as sessions came and went would read as the notch shifting,
        // which is the one illusion this design exists to avoid.
        #expect(idle.pillRect.minX == busy.pillRect.minX)
        #expect(idle.pillRect.minX == idle.notchRect.maxX + NotchLayout.default.pillGap)
    }

    @Test("leading hover slop is free — it never reaches left of the notch")
    func leadingHoverSlopIsFree() {
        for screen in [ScreenFixture.notched14, ScreenFixture.notched16] {
            for sessions in [0, 3] {
                let g = NotchGeometryResolver.resolve(
                    screen: screen,
                    listContentHeight: threeRows,
                    pillContentWidth: PillMetrics.contentWidth(sessionCount: sessions))
                // Absorbed by notch pixels the window already owns, so the hover
                // target is wider than the capsule at zero cost to anyone else.
                #expect(g.pillHotRect.minX == g.notchRect.maxX)
            }
        }
    }

    @Test("the collapsed window wastes nothing to the right of the drawn pill")
    func theCollapsedWindowWastesNothingTrailing() {
        for screen in ScreenFixture.all {
            for sessions in [0, 3] {
                let g = NotchGeometryResolver.resolve(
                    screen: screen,
                    listContentHeight: threeRows,
                    pillContentWidth: PillMetrics.contentWidth(sessionCount: sessions))
                let waste = g.collapsedFrame.maxX - g.pillContentRect.maxX
                #expect(
                    waste <= NotchGeometryResolver.maxTrailingWaste,
                    "display \(screen.displayID) sessions \(sessions) wastes \(waste) pt")
            }
        }
    }

    @Test("a padded slot is reported when it starts costing menu bar")
    func invariantCatchesAFatSlot() {
        // Somebody restores the old 52 pt slot as `pillPadding` "to make the pill
        // easier to hit". That is 8 pt of somebody else's status icon painted
        // black on the trailing side, so it must not pass quietly.
        let g = NotchGeometryResolver.resolve(
            screen: ScreenFixture.notched14,
            listContentHeight: threeRows,
            layout: NotchLayout(pillPadding: 12))
        let report = NotchGeometryResolver.check(g)
        #expect(!report.isSatisfied)
        #expect(report.violations.contains { $0.contains("right of the drawn pill") })
    }

    private func resolveNotched14(sessions: Int) -> NotchGeometry {
        NotchGeometryResolver.resolve(
            screen: ScreenFixture.notched14,
            listContentHeight: threeRows,
            pillContentWidth: PillMetrics.contentWidth(sessionCount: sessions))
    }

    @Test("the collapsed window is exactly the union, and nothing more")
    func collapsedIsTheUnion() {
        let g = NotchGeometryResolver.resolve(
            screen: ScreenFixture.notched14, listContentHeight: threeRows)
        #expect(g.collapsedFrame == g.notchRect.union(g.pillHotRect).union(g.leftCapRect))
        // The whole design in one assertion: the window is never taller than the
        // menu bar while collapsed, so there is no transparent region below it to
        // swallow clicks meant for other apps.
        #expect(g.collapsedFrame.height == g.bandHeight)
        #expect(g.collapsedFrame.maxY == g.screenFrame.maxY)
    }

    @Test("by default the collapsed window starts at the notch and takes no menu strip")
    func collapsedStartsAtTheNotchByDefault() {
        let g = NotchGeometryResolver.resolve(
            screen: ScreenFixture.notched14, listContentHeight: threeRows)
        // The default cap is zero: the strip immediately left of the notch is
        // where macOS puts the frontmost app's own menus, and a covered menu is
        // worse than a covered status icon — the clicks are swallowed either way.
        #expect(g.leftCapRect.width == 0)
        #expect(g.collapsedFrame.minX == g.notchRect.minX)
        #expect(g.expandedFrame.minX == g.collapsedFrame.minX)
    }

    @Test("the decorative left cap still works, for anyone who opts back in")
    func leftCapIsOptIn() {
        // The M3a maths, kept alive behind one constructor argument. The cap is a
        // few real screen pixels left of the notch's own edge, so painting from
        // here means OUR rounded corner reveals the black, rather than the
        // invisible one under the camera housing.
        let layout = NotchLayout(leftCapWidth: 14)
        let g = NotchGeometryResolver.resolve(
            screen: ScreenFixture.notched14, listContentHeight: threeRows, layout: layout)
        #expect(g.leftCapRect.width == 14)
        #expect(g.leftCapRect.maxX == g.notchRect.minX - layout.pillGap)
        #expect(g.collapsedFrame.minX == g.leftCapRect.minX)
        #expect(g.expandedFrame.minX == g.collapsedFrame.minX)
        #expect(NotchGeometryResolver.check(g).isSatisfied)
    }

    @Test("no interactive chrome sits in the notch's x-range")
    func pillIsClearOfTheNotch() {
        for screen in [ScreenFixture.notched14, ScreenFixture.notched16] {
            let g = NotchGeometryResolver.resolve(screen: screen, listContentHeight: threeRows)
            #expect(!g.notchRect.intersects(g.pillRect))
            #expect(g.pillRect.minX >= g.notchRect.maxX)
            // And the mask never offers anything inside the notch.
            for phase in NotchPhase.allCases {
                for rect in g.interactiveRects(for: phase) {
                    #expect(!rect.intersects(g.notchRect))
                }
            }
        }
    }

    // MARK: - Non-notch fallback

    @Test("without a notch the union collapses to the pill, one shape, no branch")
    func nonNotchFallback() {
        let g = NotchGeometryResolver.resolve(
            screen: ScreenFixture.external, listContentHeight: threeRows)
        #expect(!g.hasNotch)
        // Degenerate, and pinned at the pill's left edge…
        #expect(g.notchRect.width == 0)
        #expect(g.notchRect.minX == g.pillHotRect.minX)
        // …so `panelX == pillHot.minX` and the union is exactly the pill.
        #expect(g.collapsedFrame == g.pillHotRect)
        // A black tab hanging from the top edge, drawn by the same hierarchy.
        #expect(g.collapsedFrame.maxY == g.screenFrame.maxY)
        #expect(g.bandHeight == NotchLayout.default.fallbackBandHeight)
    }

    @Test("negative screen origins do not leak zero assumptions")
    func negativeOrigins() {
        let screen = ScreenFixture.negativeOrigin
        let g = NotchGeometryResolver.resolve(screen: screen, listContentHeight: threeRows)
        #expect(NotchGeometryResolver.check(g).isSatisfied)
        // Everything is built from `frame`, so everything lands on that display.
        #expect(screen.frame.contains(g.collapsedFrame))
        #expect(screen.frame.contains(g.expandedFrame))
        #expect(g.collapsedFrame.minX < 0)
        #expect(g.collapsedFrame.maxY == 2062) // 982 + 1080
    }

    // MARK: - Expansion

    @Test("the window only ever grows to open")
    func expandedContainsCollapsed() {
        for screen in ScreenFixture.all {
            let g = NotchGeometryResolver.resolve(screen: screen, listContentHeight: threeRows)
            #expect(g.expandedFrame.contains(g.collapsedFrame))
            #expect(g.expandedFrame.height == g.bandHeight + g.listHeight)
            // Shared top-left origin. This is what lets SwiftUI animate the
            // content inside a `.topLeading` frame while the window teleports.
            #expect(g.expandedFrame.minX == g.collapsedFrame.minX)
            #expect(g.expandedFrame.maxY == g.collapsedFrame.maxY)
        }
    }

    @Test("the list is capped at 60% of the screen and scrolls beyond it")
    func listIsCapped() {
        let screen = ScreenFixture.notched14
        let g = NotchGeometryResolver.resolve(screen: screen, listContentHeight: 4000)
        #expect(g.listHeight == screen.frame.height * 0.6)
        #expect(g.expandedFrame.height == g.bandHeight + screen.frame.height * 0.6)

        let small = NotchGeometryResolver.resolve(screen: screen, listContentHeight: 90)
        #expect(small.listHeight == 90)
    }

    @Test("an empty list still yields a valid, band-height window")
    func zeroContent() {
        let g = NotchGeometryResolver.resolve(
            screen: ScreenFixture.notched14, listContentHeight: 0)
        #expect(g.listHeight == 0)
        #expect(g.expandedFrame.height == g.bandHeight)
        #expect(g.listRect.isEmpty)
        // Nothing to click below the band, so the mask offers only the pill.
        #expect(g.interactiveRects(for: .pinned) == [g.pillRect])
        #expect(NotchGeometryResolver.check(g).isSatisfied)
    }

    // MARK: - Masks

    @Test("the notch x-range is inert in every phase")
    func maskExcludesNotch() {
        let g = NotchGeometryResolver.resolve(
            screen: ScreenFixture.notched14, listContentHeight: threeRows)
        let insideNotch = CGPoint(x: g.notchRect.midX, y: g.notchRect.midY)
        for phase in NotchPhase.allCases {
            let hit = g.interactiveRects(for: phase).contains { $0.contains(insideNotch) }
            #expect(!hit, "phase \(phase) offers a click target under the notch")
        }
    }

    @Test("collapsed offers the pill only; open also offers the list")
    func maskByPhase() {
        let g = NotchGeometryResolver.resolve(
            screen: ScreenFixture.notched14, listContentHeight: threeRows)
        #expect(g.interactiveRects(for: .collapsed) == [g.pillRect])
        #expect(g.interactiveRects(for: .peeking) == [g.pillRect, g.listRect])
        #expect(g.interactiveRects(for: .pinned) == [g.pillRect, g.listRect])
        // The list hangs BELOW the band, never over it.
        #expect(g.listRect.maxY == g.expandedFrame.maxY - g.bandHeight)
    }

    // MARK: - Coordinate conversions

    @Test("panel top and pill top are both pinned to the screen top, so the pill's SwiftUI y is 0")
    func swiftUIConversionOfThePill() {
        for screen in ScreenFixture.all {
            let g = NotchGeometryResolver.resolve(screen: screen, listContentHeight: threeRows)
            // The assertion the design calls out by name. Writing
            // `maxY - minY` instead of `maxY - maxY` is a full-rect-height error
            // that looks entirely plausible on a 32 pt band — this is what
            // catches it.
            let collapsed = NotchGeometryResolver.swiftUIRect(g.pillRect, in: g.collapsedFrame)
            #expect(collapsed.minY == 0)
            let expanded = NotchGeometryResolver.swiftUIRect(g.pillRect, in: g.expandedFrame)
            #expect(expanded.minY == 0)
            // And the x-offset is phase-independent, which is why the pill
            // provably cannot drift during the animation.
            #expect(collapsed.minX == expanded.minX)
        }
    }

    @Test("the SwiftUI conversion flips y about the window's TOP edge")
    func swiftUIConversionFlipsAboutMaxY() {
        let window = CGRect(x: 100, y: 500, width: 380, height: 200) // maxY 700
        let rect = CGRect(x: 140, y: 620, width: 40, height: 20)     // maxY 640
        let converted = NotchGeometryResolver.swiftUIRect(rect, in: window)
        #expect(converted.minX == 40)
        // 700 - 640, NOT 700 - 620.
        #expect(converted.minY == 60)
        #expect(converted.height == 20)
    }

    @Test("the window conversion is a pure translation, y-up on both sides")
    func windowConversion() {
        let window = CGRect(x: 663, y: 950, width: 239, height: 32)
        let pill = CGRect(x: 854, y: 950, width: 52, height: 32)
        let local = NotchGeometryResolver.windowRect(pill, in: window)
        #expect(local == CGRect(x: 191, y: 0, width: 52, height: 32))
    }

    @Test("a mask converted against the wrong frame is caught by the origin, not by luck")
    func windowConversionDuringCollapse() {
        let g = NotchGeometryResolver.resolve(
            screen: ScreenFixture.notched14, listContentHeight: threeRows)
        // During a collapse the window is still expanded while the mask is
        // already the collapsed one. Converting against the live frame is the
        // only correct thing; converting against `collapsedFrame` would offset
        // the pill by the list's whole height.
        let live = NotchGeometryResolver.windowRect(g.pillRect, in: g.expandedFrame)
        let wrong = NotchGeometryResolver.windowRect(g.pillRect, in: g.collapsedFrame)
        #expect(live.minY - wrong.minY == g.listHeight)
        #expect(live.maxY == g.expandedFrame.height)
    }

    // MARK: - Hover zones

    @Test("the grace corridor is built from the FINAL expanded frame")
    func corridorUsesFinalFrame() {
        let g = NotchGeometryResolver.resolve(
            screen: ScreenFixture.notched14, listContentHeight: threeRows)
        // A fast downward flick lands inside the corridor before the window has
        // finished growing, which is the only way that gesture can feel right.
        let belowThePanel = CGPoint(x: g.expandedFrame.midX, y: g.expandedFrame.minY - 8)
        #expect(g.graceCorridor.contains(belowThePanel))
        #expect(!g.expandedFrame.contains(belowThePanel))
        // Never off-screen, and always inclusive of the pill.
        #expect(g.screenFrame.contains(g.graceCorridor))
        #expect(g.graceCorridor.contains(CGPoint(x: g.pillRect.midX, y: g.pillRect.midY)))
    }

    @Test("the menu bar strip spans the whole width at band height")
    func menuBarStrip() {
        let g = NotchGeometryResolver.resolve(
            screen: ScreenFixture.notched14, listContentHeight: threeRows)
        #expect(g.menuBarStrip.width == g.screenFrame.width)
        #expect(g.menuBarStrip.height == g.bandHeight)
        #expect(g.menuBarStrip.maxY == g.screenFrame.maxY)
        // Control Center's corner, which is where the short grace matters.
        #expect(g.menuBarStrip.contains(CGPoint(x: g.screenFrame.maxX - 40, y: g.screenFrame.maxY - 10)))
    }

    // MARK: - Regression guards

    @Test("a hand-tuned layout that breaks the invariant is reported, not tolerated")
    func invariantCatchesBadTuning() {
        // Somebody adds vertical hover slop "to make it easier to hit". The
        // collapsed window would then extend below the menu bar and start
        // swallowing clicks meant for other apps — exactly the failure the
        // reference implementation warns about.
        var g = NotchGeometryResolver.resolve(
            screen: ScreenFixture.notched14, listContentHeight: threeRows)
        g = NotchGeometry(
            displayID: g.displayID,
            screenFrame: g.screenFrame,
            hasNotch: g.hasNotch,
            bandHeight: g.bandHeight,
            notchRect: g.notchRect,
            pillRect: g.pillRect,
            pillContentRect: g.pillContentRect,
            pillHotRect: g.pillHotRect.insetBy(dx: 0, dy: -20),
            leftCapRect: g.leftCapRect,
            collapsedFrame: g.collapsedFrame.insetBy(dx: 0, dy: -20),
            expandedFrame: g.expandedFrame,
            listHeight: g.listHeight,
            graceCorridor: g.graceCorridor,
            menuBarStrip: g.menuBarStrip
        )
        let report = NotchGeometryResolver.check(g)
        #expect(!report.isSatisfied)
        #expect(report.violations.contains { $0.contains("flush with the screen top") })
    }

    @Test("a narrow screen shrinks the panel rather than running off the edge")
    func narrowScreen() {
        // A 900 pt-wide display with a notch: there is not 380 pt of room to the
        // right of the notch's left edge.
        let cramped = ScreenMetrics(
            displayID: 9,
            frame: CGRect(x: 0, y: 0, width: 900, height: 600),
            auxLeftWidth: 380,
            auxRightWidth: 380,
            safeAreaTop: 32
        )
        let g = NotchGeometryResolver.resolve(screen: cramped, listContentHeight: threeRows)
        #expect(NotchGeometryResolver.check(g).isSatisfied)
        #expect(g.expandedFrame.maxX <= cramped.frame.maxX)
        #expect(g.collapsedFrame.maxX <= cramped.frame.maxX)
    }
}
