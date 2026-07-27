import CoreGraphics
import Foundation
import Testing

@testable import PeeksyCore

/// Footprints from the real 14" fixture after the Stage 1 shrink: the collapsed
/// window ends at 878 with no sessions and 900 with some.
private let idleEdge: CGFloat = 878
private let busyEdge: CGFloat = 900

@Suite("NeighbourYield")
struct NeighbourYieldTests {

    /// A trusted reading with the run starting wherever we say.
    private func reading(runAt x: CGFloat) -> MenuBarOccupancy {
        MenuBarOccupancy(
            displayID: 1,
            statusRunMinX: x,
            items: [CGRect(x: x, y: 949, width: 32, height: 33)],
            trust: .trusted)
    }

    private func untrusted() -> MenuBarOccupancy {
        MenuBarOccupancy(displayID: 1, statusRunMinX: nil, items: [],
                         trust: .untrusted(reason: "test"))
    }

    // MARK: - The decision

    @Test("a bar with room leaves the pill alone")
    func roomMeansFull() {
        var yield = NeighbourYield()
        // The real measurement on this machine, with our own status item gone.
        let changed1 = yield.apply(reading(runAt: 947), fullFootprintMaxX: busyEdge)
        #expect(!changed1)
        #expect(yield.level == .full)
    }

    @Test("one more status item still fits")
    func oneMoreItemStillFits() {
        var yield = NeighbourYield()
        yield.apply(reading(runAt: 915), fullFootprintMaxX: busyEdge)
        // 900 + 8 clearance = 908 <= 915.
        #expect(yield.level == .full)
    }

    @Test("a bar that reaches our edge makes us stand aside")
    func crowdingMeansYield() {
        var yield = NeighbourYield()
        let changed2 = yield.apply(reading(runAt: 883), fullFootprintMaxX: busyEdge)
        #expect(changed2)
        #expect(yield.level == .yielded)
    }

    @Test("the overflow that was actually observed makes us stand aside")
    func theObservedOverflowYields() {
        // A transient Screenshot item moved the run to 877 during the
        // investigation, putting 35 pt of it under the old 912 pt band. Even
        // after Stage 1 shrank us to 878, that case is still one point over —
        // shrinking alone never closed it, which is why this file exists.
        var yield = NeighbourYield()
        let changed3 = yield.apply(reading(runAt: 877), fullFootprintMaxX: idleEdge)
        #expect(changed3)
        #expect(yield.level == .yielded)
    }

    @Test("standing aside happens on the first sample, not the third")
    func escalationIsImmediate() {
        var yield = NeighbourYield()
        yield.apply(reading(runAt: 860), fullFootprintMaxX: busyEdge)
        #expect(yield.level == .yielded)
    }

    // MARK: - Coming back

    @Test("coming back needs more room than staying did")
    func releaseNeedsTheExtraMargin() {
        var yield = NeighbourYield()
        yield.apply(reading(runAt: 860), fullFootprintMaxX: busyEdge)
        #expect(yield.level == .yielded)
        // 925 would be enough to STAY at full (900 + 8 = 908), but not enough to
        // return: 900 + 8 + 24 = 932 > 925. Without the margin the pill would
        // pop in and out around a single threshold.
        for _ in 0..<5 { yield.apply(reading(runAt: 925), fullFootprintMaxX: busyEdge) }
        #expect(yield.level == .yielded)
    }

    @Test("coming back needs the room to still be there on the next sample")
    func releaseNeedsConfirmation() {
        var yield = NeighbourYield()
        yield.apply(reading(runAt: 860), fullFootprintMaxX: busyEdge)
        let changed4 = yield.apply(reading(runAt: 947), fullFootprintMaxX: busyEdge)
        #expect(!changed4)
        #expect(yield.level == .yielded)
        let changed5 = yield.apply(reading(runAt: 947), fullFootprintMaxX: busyEdge)
        #expect(changed5)
        #expect(yield.level == .full)
    }

    @Test("a bar that flickers never flaps the pill")
    func flickeringNeverReleases() {
        var yield = NeighbourYield()
        // A status item that comes and goes — a screenshot overlay, a sync
        // indicator. The confirmation counter resets on every crowded sample, so
        // this can never accumulate its way back to full.
        for _ in 0..<20 {
            yield.apply(reading(runAt: 947), fullFootprintMaxX: busyEdge)
            yield.apply(reading(runAt: 860), fullFootprintMaxX: busyEdge)
        }
        #expect(yield.level == .yielded)
    }

    // MARK: - Untrusted

    @Test("an untrusted sample holds, in BOTH directions")
    func untrustedHolds() {
        // From full it must not hide: a broken window list would otherwise make
        // the app vanish, which LEARNINGS records as indistinguishable from a
        // crash.
        var fromFull = NeighbourYield()
        let changed6 = fromFull.apply(untrusted(), fullFootprintMaxX: busyEdge)
        #expect(!changed6)
        #expect(fromFull.level == .full)

        // From yielded it must not return: releasing on no evidence would put
        // the black band straight back over somebody's icon.
        var fromYielded = NeighbourYield()
        fromYielded.apply(reading(runAt: 860), fullFootprintMaxX: busyEdge)
        let changed7 = fromYielded.apply(untrusted(), fullFootprintMaxX: busyEdge)
        #expect(!changed7)
        #expect(fromYielded.level == .yielded)
    }

    @Test("an untrusted sample resets a release in progress")
    func untrustedResetsTheCounter() {
        var yield = NeighbourYield()
        yield.apply(reading(runAt: 860), fullFootprintMaxX: busyEdge)
        yield.apply(reading(runAt: 947), fullFootprintMaxX: busyEdge)  // 1 of 2
        yield.apply(untrusted(), fullFootprintMaxX: busyEdge)          // discard
        yield.apply(reading(runAt: 947), fullFootprintMaxX: busyEdge)  // 1 of 2 again
        #expect(yield.level == .yielded)
    }

    @Test("a trusted reading with no items is not an empty menu bar")
    func nilRunHolds() {
        var yield = NeighbourYield()
        let noItems = MenuBarOccupancy(displayID: 1, statusRunMinX: nil, items: [],
                                       trust: .trusted)
        let changed8 = yield.apply(noItems, fullFootprintMaxX: busyEdge)
        #expect(!changed8)
        #expect(yield.level == .full)
    }

    // MARK: - Mechanics

    @Test("apply reports movement, so the caller can skip the common case")
    func applyReportsOnlyRealChanges() {
        var yield = NeighbourYield()
        let changed9 = yield.apply(reading(runAt: 947), fullFootprintMaxX: busyEdge)
        #expect(!changed9)
        let changed10 = yield.apply(reading(runAt: 860), fullFootprintMaxX: busyEdge)
        #expect(changed10)
        let changed11 = yield.apply(reading(runAt: 860), fullFootprintMaxX: busyEdge)
        #expect(!changed11)
    }

    @Test("yielding zeroes the pill width the resolver is asked for")
    func pillWidthFollowsTheLevel() {
        var yield = NeighbourYield()
        #expect(yield.pillContentWidth(wanting: 44) == 44)
        yield.apply(reading(runAt: 860), fullFootprintMaxX: busyEdge)
        #expect(yield.pillContentWidth(wanting: 44) == 0)
    }

    @Test("the idle pill survives a bar that the busy pill does not")
    func theIdlePillFitsInLessRoom() {
        // 22 pt narrower, which is a whole status icon's worth of difference.
        var idle = NeighbourYield()
        var busy = NeighbourYield()
        idle.apply(reading(runAt: 890), fullFootprintMaxX: idleEdge)
        busy.apply(reading(runAt: 890), fullFootprintMaxX: busyEdge)
        #expect(idle.level == .full)
        #expect(busy.level == .yielded)
    }
}
