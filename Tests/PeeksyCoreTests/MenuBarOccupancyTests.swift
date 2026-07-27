import CoreGraphics
import Foundation
import Testing

@testable import PeeksyCore

/// Window lists captured from a real menu bar, in raw `kCGWindowBounds` space
/// (top-left origin, y DOWN) exactly as `CGWindowListCopyWindowInfo` returns
/// them. Same doctrine as `ScreenFixture`: test against numbers the machine
/// actually produced, not against numbers that seemed reasonable.
enum MenuBarFixture {

    /// The primary display's height, which is the whole of the y-flip.
    static let primaryMaxY: CGFloat = 982

    /// 14 status items on a 1512 pt display, captured while Peeksy was
    /// running. `17691` is Peeksy's own 17 pt anchor at the left end of the
    /// run; `38` is the clock, and its bounds END AT 1514 — two points past the
    /// screen's right edge, which is why display attribution uses the midpoint.
    static let busy14: [StatusWindow] = [
        item(17691, 930, 17), item(15952, 947, 32), item(7137, 979, 40),
        item(4921, 1019, 36), item(125, 1055, 32), item(44, 1087, 38),
        item(40, 1125, 33), item(37, 1158, 42), item(17167, 1200, 33),
        item(41, 1233, 38), item(1228, 1271, 32), item(45, 1303, 32),
        item(42, 1335, 42), item(38, 1377, 137),
    ]

    /// The same bar with two more items, so the run reaches back past where the
    /// pill sits. Synthesised by extending the real run leftward at the observed
    /// item widths — the ARRANGEMENT is synthetic, the widths are not.
    static let overflowing: [StatusWindow] = [item(900, 877, 32), item(901, 909, 21)]
        + busy14.filter { $0.windowID != 17691 }

    /// Things that are in the window list and are not status items: the menu bar
    /// itself at layer 24 (captured: 0,0 1512x33), Peeksy's panel at
    /// shielding level (captured: 643,0 269x32), and an ordinary app window.
    static let noise: [StatusWindow] = [
        StatusWindow(windowID: 900_001, layer: 24, cgBounds: CGRect(x: 0, y: 0, width: 1512, height: 33)),
        StatusWindow(windowID: 900_002, layer: 2_147_483_627, cgBounds: CGRect(x: 643, y: 0, width: 269, height: 32)),
        StatusWindow(windowID: 900_003, layer: 0, cgBounds: CGRect(x: 100, y: 400, width: 800, height: 600)),
    ]

    /// One status item at the observed transient offset: `y = -3`, i.e. three
    /// points above the physical screen top. Steady state is `y = 0`.
    static let transientlyRaised = StatusWindow(
        windowID: 910_001, layer: 25, cgBounds: CGRect(x: 1200, y: -3, width: 33, height: 33))

    /// SYNTHESISED, not observed: an open status menu hanging down over the
    /// desktop. It is a layer-25 window too, and admitting one would drag
    /// `statusRunMinX` hundreds of points left.
    static let openStatusMenu = StatusWindow(
        windowID: 920_001, layer: 25, cgBounds: CGRect(x: 1100, y: 0, width: 260, height: 480))

    static func item(_ id: UInt32, _ x: CGFloat, _ width: CGFloat) -> StatusWindow {
        StatusWindow(windowID: id, layer: 25,
                     cgBounds: CGRect(x: x, y: 0, width: width, height: 33))
    }
}

@Suite("MenuBarOccupancy")
struct MenuBarOccupancyTests {

    private func occupancy(
        _ windows: [StatusWindow],
        screen: ScreenMetrics = ScreenFixture.notched14,
        calibration: (windowID: UInt32, appKitFrame: CGRect)? = nil
    ) -> MenuBarOccupancy {
        MenuBarScan.occupancy(
            windows: windows,
            screen: screen,
            bandHeight: 32,
            primaryScreenMaxY: MenuBarFixture.primaryMaxY,
            calibration: calibration)
    }

    // MARK: - The coordinate flip

    @Test("CG bounds flip about the PRIMARY display's top, not its origin")
    func conversionFlipsAboutTheTop() {
        // The clock, as captured.
        let cg = CGRect(x: 1377, y: 0, width: 137, height: 33)
        let ak = MenuBarScan.appKitRect(fromCGWindowBounds: cg, primaryScreenMaxY: 982)
        #expect(ak == CGRect(x: 1377, y: 949, width: 137, height: 33))
        // Flush with the screen top, which is the whole point of a menu bar item.
        #expect(ak.maxY == 982)
        // And NOT the plausible-looking wrong formula, `primaryMaxY - cg.minY`,
        // which is off by the rect's full height — 33 pt on a 32 pt band. Every
        // item would land one band low, the filter would return nothing, and an
        // empty result reads as "the menu bar is empty".
        #expect(ak.minY != 982 - cg.minY)
    }

    @Test("a display above the primary converts to a y greater than the primary's height")
    func conversionHandlesADisplayAboveThePrimary() {
        // CG space runs downward from the primary's top, so a display stacked
        // above it has NEGATIVE y.
        let cg = CGRect(x: 200, y: -1100, width: 32, height: 33)
        let ak = MenuBarScan.appKitRect(fromCGWindowBounds: cg, primaryScreenMaxY: 982)
        // 982 - (-1100 + 33)
        #expect(ak.minY == 2049)
        #expect(ak.maxY == 2082)
        #expect(ak.minY > 982)
    }

    // MARK: - Filtering

    @Test("only the status layer survives")
    func rejectsEveryOtherLayer() {
        let result = occupancy(MenuBarFixture.busy14 + MenuBarFixture.noise)
        #expect(result.items.count == MenuBarFixture.busy14.count)
        #expect(result.statusRunMinX == 930)
    }

    @Test("a tall layer-25 window is an open menu, not an item")
    func rejectsAnOpenStatusMenu() {
        let result = occupancy(MenuBarFixture.busy14 + [MenuBarFixture.openStatusMenu])
        #expect(result.items.count == MenuBarFixture.busy14.count)
        // Admitting it would have dragged the run left to 1100 and made us yield
        // to a menu that is about to close.
        #expect(result.statusRunMinX == 930)
    }

    @Test("an item on another display is not ours to yield to")
    func rejectsAnotherDisplaysItems() {
        let elsewhere = MenuBarFixture.item(930_001, 2000, 32)
        let result = occupancy(MenuBarFixture.busy14 + [elsewhere])
        #expect(result.items.count == MenuBarFixture.busy14.count)
    }

    @Test("a fully transparent item is not occupying anything")
    func rejectsZeroAlpha() {
        let ghost = StatusWindow(windowID: 940_001, layer: 25,
                                 cgBounds: CGRect(x: 900, y: 0, width: 30, height: 33),
                                 alpha: 0)
        let result = occupancy(MenuBarFixture.busy14 + [ghost])
        #expect(result.statusRunMinX == 930)
    }

    @Test("the clock's two-point overhang past the screen edge is kept")
    func keepsTheItemThatOverhangsTheScreenEdge() {
        let result = occupancy(MenuBarFixture.busy14)
        // Captured: 1377 + 137 = 1514 on a 1512 pt display. Containment would
        // drop it, the run would then end 135 pt short, and every sample would
        // read untrusted.
        #expect(result.items.contains { $0.maxX == 1514 })
        #expect(result.trust.isTrusted)
    }

    @Test("the transient three-point rise above the screen top is tolerated")
    func toleratesTheTransientRaisedItem() {
        // Observed live: items reporting y = -3 in CG space while the steady
        // state is y = 0. Rejecting them would empty the whole sample.
        let raised = MenuBarFixture.busy14.map {
            StatusWindow(windowID: $0.windowID, layer: $0.layer,
                         cgBounds: $0.cgBounds.offsetBy(dx: 0, dy: -3), alpha: $0.alpha)
        }
        let result = occupancy(raised)
        #expect(result.items.count == MenuBarFixture.busy14.count)
        #expect(result.trust.isTrusted)
        #expect(occupancy([MenuBarFixture.transientlyRaised]).items.count == 1)
    }

    // MARK: - Trust

    @Test("a real, contiguous, right-anchored run is trusted")
    func realCaptureIsTrusted() {
        let result = occupancy(MenuBarFixture.busy14)
        #expect(result.trust.isTrusted)
        #expect(result.statusRunMinX == 930)
        #expect(result.items.count == 14)
    }

    @Test("a hole in the run means the bounds cannot be believed")
    func aGapMakesTheSampleUntrusted() {
        // macOS packs status items with no gaps. A 200 pt hole means we are not
        // looking at what we think we are looking at.
        let holed = MenuBarFixture.busy14.filter { $0.windowID != 125 && $0.windowID != 44 }
        let result = occupancy(holed)
        #expect(!result.trust.isTrusted)
    }

    @Test("a run that stops short of the screen edge is not a right-aligned run")
    func aShortRunIsUntrusted() {
        let truncated = MenuBarFixture.busy14.filter { $0.windowID != 38 }
        let result = occupancy(truncated)
        #expect(!result.trust.isTrusted)
    }

    @Test("an empty sample is untrusted, NOT an empty menu bar")
    func emptyIsUntrustedRatherThanEmpty() {
        let result = occupancy(MenuBarFixture.noise)
        #expect(result.statusRunMinX == nil)
        #expect(!result.trust.isTrusted)
        // The distinction the whole design rests on: "I could not see" and
        // "there is nothing there" mean opposite things to a yield policy.
        #expect(result.items.isEmpty)
    }

    // MARK: - Calibration

    @Test("a calibration window that converts correctly keeps the sample trusted")
    func calibrationAgreeing() {
        // Our own panel, as captured: CG 643,0 269x32 → AppKit 643,950 269x32,
        // which is exactly the collapsedFrame the resolver produces.
        let panel = StatusWindow(windowID: 950_001, layer: 2_147_483_627,
                                 cgBounds: CGRect(x: 643, y: 0, width: 269, height: 32))
        let result = occupancy(
            MenuBarFixture.busy14 + [panel],
            calibration: (950_001, CGRect(x: 643, y: 950, width: 269, height: 32)))
        #expect(result.trust.isTrusted)
    }

    @Test("a calibration window that disagrees distrusts everything")
    func calibrationDisagreeing() {
        // If the bounds or the flip are wrong, they are wrong for every item in
        // the same direction and the result would look perfectly reasonable.
        // This is the check that notices.
        let panel = StatusWindow(windowID: 950_001, layer: 2_147_483_627,
                                 cgBounds: CGRect(x: 643, y: 0, width: 269, height: 32))
        let result = occupancy(
            MenuBarFixture.busy14 + [panel],
            calibration: (950_001, CGRect(x: 1200, y: 950, width: 269, height: 32)))
        #expect(!result.trust.isTrusted)
        #expect(result.statusRunMinX == nil)
    }

    @Test("a calibration window that is not on screen is not a failure")
    func calibrationAbsent() {
        // Our panel is legitimately absent while ordered out. A window that is
        // not in the list cannot disagree with anything.
        let result = occupancy(
            MenuBarFixture.busy14,
            calibration: (999_999, CGRect(x: 643, y: 950, width: 269, height: 32)))
        #expect(result.trust.isTrusted)
    }

    // MARK: - Clearance

    @Test("clearance measures the gap between our right edge and the run")
    func clearanceIsTheGap() {
        let result = occupancy(MenuBarFixture.busy14)
        #expect(result.clearance(rightOf: 878) == 52)
        #expect(result.clearance(rightOf: 900) == 30)
        // Negative means we are covering somebody.
        #expect(result.clearance(rightOf: 950) == -20)
    }

    // MARK: - Presence

    private func menuBarWindow(
        _ windows: [StatusWindow],
        screen: ScreenMetrics = ScreenFixture.notched14
    ) -> CGRect? {
        MenuBarScan.menuBarWindow(
            in: screen,
            bandHeight: 32,
            windows: windows,
            primaryScreenMaxY: MenuBarFixture.primaryMaxY)
    }

    @Test("the menu bar's own window is what says there is a menu bar")
    func findsTheMenuBarWindow() {
        // Captured: layer 24, 0,0 1512x33.
        let rect = menuBarWindow(MenuBarFixture.busy14 + MenuBarFixture.noise)
        #expect(rect == CGRect(x: 0, y: 949, width: 1512, height: 33))
    }

    @Test("an auto-hidden menu bar is parked above the screen, not removed")
    func autoHiddenMenuBarReadsAsAbsent() {
        // macOS slides that window above the top edge rather than deleting it,
        // so it is still on screen and still full width. Requiring it to overlap
        // the band is what catches it — the same trick the old status-item
        // anchor used, without the status item.
        let parked = StatusWindow(
            windowID: 900_001, layer: 24,
            cgBounds: CGRect(x: 0, y: -40, width: 1512, height: 33))
        #expect(menuBarWindow([parked]) == nil)
    }

    @Test("a narrow layer-24 window is not the menu bar")
    func rejectsANarrowMenuBarLayerWindow() {
        let notTheBar = StatusWindow(
            windowID: 900_009, layer: 24,
            cgBounds: CGRect(x: 400, y: 0, width: 300, height: 33))
        #expect(menuBarWindow([notTheBar]) == nil)
    }

    @Test("status items alone do not prove there is a menu bar")
    func statusItemsAreNotTheMenuBar() {
        #expect(menuBarWindow(MenuBarFixture.busy14) == nil)
    }

    @Test("another display's menu bar is not this display's")
    func rejectsAnotherDisplaysMenuBar() {
        // A second display to the right, with its own bar.
        let elsewhere = StatusWindow(
            windowID: 900_010, layer: 24,
            cgBounds: CGRect(x: 1512, y: 0, width: 1512, height: 33))
        #expect(menuBarWindow([elsewhere]) == nil)
    }

    @Test("the overflowing bar reaches back past where the pill sits")
    func overflowingBarOverlapsThePill() {
        let result = occupancy(MenuBarFixture.overflowing)
        #expect(result.statusRunMinX == 877)
        // Stage 1's shrink alone is not enough here — 878 is still one point
        // over. This is exactly the case the yield policy exists for.
        #expect((result.clearance(rightOf: 878) ?? 0) < 0)
    }
}
