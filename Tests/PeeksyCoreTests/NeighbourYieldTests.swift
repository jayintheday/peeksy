import CoreGraphics
import Foundation
import Testing

@testable import PeeksyCore

/// Footprints from the real 14" fixture after the Stage 1 shrink: the collapsed
/// window ends at 878 with no sessions and 900 with some.
private let idleEdge: CGFloat = 878
private let busyEdge: CGFloat = 900

/// The counted pill, with the bare dot as its fallback. These are the SAME two
/// numbers: the compact pill is the idle pill's width, drawn while there is
/// something to count.
private let busyPill = YieldFootprints(full: busyEdge, compact: idleEdge)
/// Nothing to count, so there is nothing to drop — both levels are one width,
/// and `.compact` can never be an improvement over `.full` here.
private let idlePill = YieldFootprints(full: idleEdge, compact: idleEdge)

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
        let changed1 = yield.apply(reading(runAt: 947), footprints: busyPill)
        #expect(!changed1)
        #expect(yield.level == .full)
    }

    @Test("one more status item still fits")
    func oneMoreItemStillFits() {
        var yield = NeighbourYield()
        yield.apply(reading(runAt: 915), footprints: busyPill)
        // 900 + 8 clearance = 908 <= 915.
        #expect(yield.level == .full)
    }

    @Test("a bar that reaches our edge makes us stand aside")
    func crowdingMeansYield() {
        var yield = NeighbourYield()
        let changed2 = yield.apply(reading(runAt: 883), footprints: busyPill)
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
        let changed3 = yield.apply(reading(runAt: 877), footprints: idlePill)
        #expect(changed3)
        #expect(yield.level == .yielded)
    }

    @Test("standing aside happens on the first sample, not the third")
    func escalationIsImmediate() {
        var yield = NeighbourYield()
        yield.apply(reading(runAt: 860), footprints: busyPill)
        #expect(yield.level == .yielded)
    }

    // MARK: - Coming back

    @Test("coming back to FULL needs more room than staying there did")
    func releaseNeedsTheExtraMargin() {
        var yield = NeighbourYield()
        yield.apply(reading(runAt: 860), footprints: busyPill)
        #expect(yield.level == .yielded)
        // 925 would be enough to STAY at full (900 + 8 = 908), but not enough to
        // return: 900 + 8 + 24 = 932 > 925. Without the margin the pill would
        // pop in and out around a single threshold.
        for _ in 0..<5 { yield.apply(reading(runAt: 925), footprints: busyPill) }
        #expect(yield.level != .full)
        // It does climb to the dot, which clears 925 with its margin to spare
        // (878 + 8 + 24 = 910). Half a pill is not a consolation prize here —
        // it is the difference between an app you can click and one you cannot.
        #expect(yield.level == .compact)
    }

    @Test("coming back needs the room to still be there on the next sample")
    func releaseNeedsConfirmation() {
        var yield = NeighbourYield()
        yield.apply(reading(runAt: 860), footprints: busyPill)
        let changed4 = yield.apply(reading(runAt: 947), footprints: busyPill)
        #expect(!changed4)
        #expect(yield.level == .yielded)
        let changed5 = yield.apply(reading(runAt: 947), footprints: busyPill)
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
            yield.apply(reading(runAt: 947), footprints: busyPill)
            yield.apply(reading(runAt: 860), footprints: busyPill)
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
        let changed6 = fromFull.apply(untrusted(), footprints: busyPill)
        #expect(!changed6)
        #expect(fromFull.level == .full)

        // From yielded it must not return: releasing on no evidence would put
        // the black band straight back over somebody's icon.
        var fromYielded = NeighbourYield()
        fromYielded.apply(reading(runAt: 860), footprints: busyPill)
        let changed7 = fromYielded.apply(untrusted(), footprints: busyPill)
        #expect(!changed7)
        #expect(fromYielded.level == .yielded)
    }

    @Test("an untrusted sample resets a release in progress")
    func untrustedResetsTheCounter() {
        var yield = NeighbourYield()
        yield.apply(reading(runAt: 860), footprints: busyPill)
        yield.apply(reading(runAt: 947), footprints: busyPill)  // 1 of 2
        yield.apply(untrusted(), footprints: busyPill)          // discard
        yield.apply(reading(runAt: 947), footprints: busyPill)  // 1 of 2 again
        #expect(yield.level == .yielded)
    }

    @Test("a trusted reading with no items is not an empty menu bar")
    func nilRunHolds() {
        var yield = NeighbourYield()
        let noItems = MenuBarOccupancy(displayID: 1, statusRunMinX: nil, items: [],
                                       trust: .trusted)
        let changed8 = yield.apply(noItems, footprints: busyPill)
        #expect(!changed8)
        #expect(yield.level == .full)
    }

    // MARK: - Mechanics

    @Test("apply reports movement, so the caller can skip the common case")
    func applyReportsOnlyRealChanges() {
        var yield = NeighbourYield()
        let changed9 = yield.apply(reading(runAt: 947), footprints: busyPill)
        #expect(!changed9)
        let changed10 = yield.apply(reading(runAt: 860), footprints: busyPill)
        #expect(changed10)
        let changed11 = yield.apply(reading(runAt: 860), footprints: busyPill)
        #expect(!changed11)
    }

    @Test("yielding zeroes the pill width the resolver is asked for")
    func pillWidthFollowsTheLevel() {
        var yield = NeighbourYield()
        #expect(yield.pillContentWidth(wanting: 44) == 44)
        yield.apply(reading(runAt: 860), footprints: busyPill)
        #expect(yield.pillContentWidth(wanting: 44) == 0)
    }

    @Test("the idle pill survives a bar that the counted pill does not")
    func theIdlePillFitsInLessRoom() {
        // 22 pt narrower, which is a whole status icon's worth of difference.
        // The counted pill cannot stay at `.full` here — but it does NOT have to
        // disappear either: what it falls back to is that same idle width.
        var idle = NeighbourYield()
        var busy = NeighbourYield()
        idle.apply(reading(runAt: 890), footprints: idlePill)
        busy.apply(reading(runAt: 890), footprints: busyPill)
        #expect(idle.level == .full)
        #expect(busy.level == .compact)
    }

    // MARK: - Compact

    /// The case this level was added for, in the numbers it was measured in.
    /// A webcam indicator put the status run at 902. The counted pill ends at
    /// 900 and needs 908 — six points short. The dot ends at 878 and needs 886.
    @Test("the webcam case: the capsule cannot stay, the dot can")
    func theWebcamCase() {
        var yield = NeighbourYield()
        let changed = yield.apply(reading(runAt: 902), footprints: busyPill)
        #expect(changed)
        #expect(yield.level == .compact)
        // 22 pt asked for instead of 44 — and crucially not 0, so the pill is
        // still on screen and still clickable.
        #expect(yield.pillContentWidth(wanting: 44) == PillMetrics.capsuleHeight)
    }

    @Test("compact is skipped entirely when even the dot will not fit")
    func compactIsNotAStopOnTheWayDown() {
        var yield = NeighbourYield()
        // 870: the dot needs 886. Straight to yielded, on one sample — standing
        // further aside is never something to phase in gradually.
        yield.apply(reading(runAt: 870), footprints: busyPill)
        #expect(yield.level == .yielded)
    }

    @Test("with nothing to count there is nothing to drop, so compact never appears")
    func idlePillHasNoCompactStep() {
        var yield = NeighbourYield()
        // Both footprints are 878 here, so any bar that refuses the pill refuses
        // it outright. A `.compact` that drew the same width as `.full` would be
        // a level that changes nothing.
        yield.apply(reading(runAt: 880), footprints: idlePill)
        #expect(yield.level == .yielded)
    }

    @Test("growing back from compact needs the margin too, not just from yielded")
    func compactToFullNeedsTheMargin() {
        var yield = NeighbourYield()
        yield.apply(reading(runAt: 902), footprints: busyPill)
        #expect(yield.level == .compact)

        // 925 is enough to STAY at full (908) but not to earn it back (932).
        for _ in 0..<5 { yield.apply(reading(runAt: 925), footprints: busyPill) }
        #expect(yield.level == .compact)

        // 932 clears it, and still needs confirming.
        let first = yield.apply(reading(runAt: 932), footprints: busyPill)
        #expect(!first)
        let second = yield.apply(reading(runAt: 932), footprints: busyPill)
        #expect(second)
        #expect(yield.level == .full)
    }

    @Test("a bar that flickers around the compact threshold never flaps the pill")
    func flickeringNeverGrows() {
        var yield = NeighbourYield()
        yield.apply(reading(runAt: 870), footprints: busyPill)
        for _ in 0..<20 {
            yield.apply(reading(runAt: 902), footprints: busyPill)  // dot would fit
            yield.apply(reading(runAt: 870), footprints: busyPill)  // nothing fits
        }
        #expect(yield.level == .yielded)
    }
}
